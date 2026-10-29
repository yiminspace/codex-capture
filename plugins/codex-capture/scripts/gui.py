"""Loopback workbench over Codex Capture's durable job records (stdlib only)."""
from __future__ import annotations

import collections
import datetime as dt
import errno
import fcntl
import hmac
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit
from urllib.request import ProxyHandler, Request, build_opener

VERSION = "0.4.3"
WEB_ROOT = Path(__file__).resolve().parent.parent / "web"
TERMINAL = {"completed", "failed", "cancelled", "needs_input", "interrupted"}
PHASE_LABELS = {
    "queued": "等待开始", "connecting": "连接 Codex", "classifying": "判断项目",
    "creating_thread": "创建对话", "starting_initial": "开始首轮", "running_initial": "任务执行中",
    "initial_finished": "首轮已结束", "starting_followup": "自动跟进中", "running_followup": "自动跟进中",
    "followup_finished": "跟进已结束", "completed": "流程已结束", "failed": "运行失败",
    "cancelled": "已取消", "needs_input": "需要处理", "interrupted": "后台已退出", "unknown": "记录不完整",
}
JOB_ID = re.compile(r"[0-9a-f][0-9a-f-]{7,63}\Z")
THREAD_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
_EVENT_CACHE = collections.OrderedDict()
_EVENT_CACHE_LOCK = threading.Lock()
_EVENT_CACHE_BYTES = 0


class ApiError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
    temporary.chmod(0o600)
    temporary.replace(path)


def safe_path(root, *parts):
    """Reject symlinks at every child component, including links within root."""
    root = Path(root).resolve()
    candidate = root.joinpath(*parts)
    try:
        relative = candidate.relative_to(root)
    except ValueError:
        raise ApiError(404, "找不到该文件")
    current = root
    for part in relative.parts:
        if part in ("..", "."):
            raise ApiError(404, "找不到该文件")
        current = current / part
        if current.is_symlink():
            raise ApiError(404, "不读取符号链接")
    try:
        candidate.resolve().relative_to(root)
    except ValueError:
        raise ApiError(404, "找不到该文件")
    return candidate


def read_object(path, warnings=None, limit=2 * 1024 * 1024):
    try:
        with path.open("rb") as stream:
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise ValueError("文件过大")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("应为 JSON 对象")
        return value
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        if warnings is not None:
            warnings.append(f"{path.name} 无法读取：{exc}")
        return {}


def read_events(path, keep=300):
    global _EVENT_CACHE_BYTES
    key, stamp = (str(path), keep), None
    try:
        stat = path.stat()
        stamp = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
        with _EVENT_CACHE_LOCK:
            cached = _EVENT_CACHE.get(key)
            if cached and cached[0] == stamp:
                _EVENT_CACHE.move_to_end(key)
                return list(cached[1]), cached[2], cached[3]
    except OSError:
        pass
    rows, count, malformed = collections.deque(maxlen=keep), 0, 0
    try:
        with path.open("rb") as stream:
            while True:
                line = stream.readline(128 * 1024 + 1)
                if not line:
                    break
                count += 1
                if len(line) > 128 * 1024:
                    # Discard the rest of this oversized line without allocating it.
                    while line and not line.endswith(b"\n"):
                        line = stream.readline(128 * 1024)
                    malformed += 1
                    continue
                try:
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise ValueError("not an object")
                    # Reasoning item metadata is enough; no hidden reasoning text is shown.
                    if value.get("itemType") == "reasoning":
                        value = {k: v for k, v in value.items() if k not in ("text", "summary", "content")}
                    rows.append(value)
                except (ValueError, UnicodeError):
                    malformed += 1
    except FileNotFoundError:
        pass
    except OSError:
        malformed += 1
    result = list(rows)
    # Keep frequent polling cheap, without retaining arbitrary log sizes in RAM.
    if stamp is not None and stamp[1] <= 2 * 1024 * 1024:
        weight = max(512, stamp[1])
        with _EVENT_CACHE_LOCK:
            previous = _EVENT_CACHE.pop(key, None)
            if previous:
                _EVENT_CACHE_BYTES -= previous[4]
            _EVENT_CACHE[key] = (stamp, result, count, malformed, weight)
            _EVENT_CACHE_BYTES += weight
            while len(_EVENT_CACHE) > 128 or _EVENT_CACHE_BYTES > 8 * 1024 * 1024:
                _, removed = _EVENT_CACHE.popitem(last=False)
                _EVENT_CACHE_BYTES -= removed[4]
    return result, count, malformed


def read_log(path, limit=32768):
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            size = stream.tell()
            stream.seek(max(0, size - limit))
            data = stream.read(limit)
        return ("[仅显示最后 32 KiB]\n" if size > limit else "") + data.decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ""
    except OSError as exc:
        return "日志无法读取：" + str(exc)


def parse_time(value):
    try:
        if isinstance(value, (float, int)):
            return float(value)
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError, AttributeError, OverflowError):
        return None


def worker_alive(state, job_id):
    pid = state.get("workerPid")
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=2)
        if result.returncode:
            return False
        return "capture.py" in result.stdout and bool(re.search(r"(?:^|\s)_worker\s+" + re.escape(job_id) + r"(?:\s|$)", result.stdout))
    except (OSError, subprocess.TimeoutExpired):
        return None


class JobStore:
    def __init__(self, data_directory):
        self.root = Path(data_directory).expanduser().resolve()

    def directory(self, job_id):
        if not JOB_ID.fullmatch(job_id):
            raise ApiError(404, "找不到该任务")
        directory = safe_path(self.root, "jobs", job_id)
        if not directory.is_dir():
            raise ApiError(404, "找不到该任务")
        return directory

    def read(self, job_id, detail=False):
        directory = self.directory(job_id)
        warnings = []
        state = read_object(safe_path(directory, "state.json"), warnings)
        request = read_object(safe_path(directory, "request.json"), warnings)
        route = read_object(safe_path(directory, "route.json"), warnings)
        if not state:
            warnings.append("缺少有效的任务状态记录")
        phase = state.get("phase", "unknown")
        if not isinstance(phase, str) or phase not in PHASE_LABELS:
            phase = "unknown"
        derived = phase
        is_active = phase not in TERMINAL and phase != "unknown"
        if is_active:
            alive = worker_alive(state, job_id)
            # A freshly queued request briefly precedes its detached worker.
            created = parse_time(state.get("createdAt"))
            if alive is False and not (phase == "queued" and created and time.time() - created < 10):
                derived, is_active = "interrupted", False
                warnings.append("后台进程已退出，记录未更新为结束状态；未自动重试或补发消息。")
            elif alive is None:
                warnings.append("暂时无法确认后台进程状态")
        events, event_count, bad_events = read_events(safe_path(directory, "events.jsonl"))
        if bad_events:
            warnings.append(f"事件日志中有 {bad_events} 行不完整或无法读取")
        failed = sum(event.get("status") == "failed" for event in events)
        if failed:
            warnings.append(f"可见事件中有 {failed} 项工具执行失败；流程结束不代表全部检查通过。")
        image = self.image_path(job_id, request, optional=True)
        created = state.get("createdAt")
        if not isinstance(created, str) or parse_time(created) is None:
            created = dt.datetime.fromtimestamp(directory.stat().st_mtime, dt.timezone.utc).isoformat()
        start = parse_time(state.get("startedAt")) or parse_time(created) or time.time()
        end = parse_time(state.get("completedAt"))
        if not is_active and end is None:
            end = parse_time(state.get("updatedAt")) or start
        duration = max(0, (end if end is not None else time.time()) - start)
        project = state.get("project") if isinstance(state.get("project"), dict) else {}
        text = request.get("text", "")
        text = text if isinstance(text, str) else ""
        title = route.get("title") or text.split("\n")[0] or "未命名截图任务"
        error = state.get("error")
        summary = {
            "jobId": job_id, "text": text[:2000], "title": str(title)[:200], "phase": phase,
            "derivedPhase": derived, "phaseLabel": PHASE_LABELS[derived], "projectName": str(project.get("name") or "尚未确定"),
            "createdAt": created, "updatedAt": state.get("updatedAt", created), "elapsedSeconds": round(duration, 1),
            "threadId": state.get("threadId") if isinstance(state.get("threadId"), str) else None, "hasImage": bool(image), "error": error,
            "warningCount": len(warnings), "isActive": is_active,
            "cancelRequested": safe_path(directory, "cancel").is_file(),
        }
        if not detail:
            return summary
        lifecycle, life_count, bad_life = read_events(safe_path(directory, "lifecycle.jsonl"))
        if bad_life:
            warnings.append(f"阶段记录中有 {bad_life} 行不完整或无法读取")
        # Older versions wrote result files before adding the corresponding state field.
        for stage, field in (("initial", "initialTurn"), ("followup", "followupTurn")):
            if field not in state:
                result = read_object(safe_path(directory, stage + ".json"), warnings)
                if result:
                    state[field] = result
        summary["warningCount"] = len(warnings)
        return {"jobId": job_id, "state": state, "request": request, "route": route,
                "events": events, "eventsTotal": event_count, "eventsTruncated": event_count > len(events),
                "lifecycle": lifecycle, "lifecycleTotal": life_count, "lifecycleTruncated": life_count > len(lifecycle),
                "logs": {name: read_log(safe_path(directory, name)) for name in ("worker.log", "app-server.stderr.log")},
                "warnings": warnings, "summary": summary}

    def image_path(self, job_id, request=None, optional=False):
        directory = self.directory(job_id)
        request = request or read_object(safe_path(directory, "request.json"))
        recorded = request.get("image")
        candidates = []
        if isinstance(recorded, str):
            original = Path(recorded)
            # Request paths may come from older installs; never serve a path outside this job.
            if original.parent == directory:
                candidates.append(original.name)
        candidates.extend("screenshot" + suffix for suffix in (".png", ".jpg", ".jpeg", ".webp", ".gif"))
        for name in dict.fromkeys(candidates):
            if Path(name).suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp", ".gif"):
                continue
            try:
                path = safe_path(directory, name)
                if path.is_file():
                    return path
            except ApiError:
                continue
        if optional:
            return None
        raise ApiError(404, "此任务没有可用截图")

    def listing(self, params):
        try:
            limit = max(1, min(100, int(params.get("limit", ["50"])[0])))
            offset = max(0, int(params.get("offset", ["0"])[0]))
        except ValueError:
            raise ApiError(400, "分页参数无效")
        search = params.get("q", [""])[0].casefold().strip()
        status = params.get("status", ["all"])[0]
        project = params.get("project", [""])[0]
        if status not in ("all", "active", "completed", "attention"):
            raise ApiError(400, "状态筛选无效")
        jobs = []
        jobs_root = safe_path(self.root, "jobs")
        if jobs_root.is_dir():
            for child in jobs_root.iterdir():
                if JOB_ID.fullmatch(child.name) and child.is_dir() and not child.is_symlink():
                    try:
                        jobs.append(self.read(child.name))
                    except ApiError:
                        # A symlink or concurrent removal must not expose another path.
                        continue
        jobs.sort(key=lambda job: parse_time(job["createdAt"]) or 0, reverse=True)
        counts = {"all": len(jobs), "active": 0, "completed": 0, "attention": 0}
        def category(job):
            return "active" if job["isActive"] else "completed" if job["derivedPhase"] == "completed" else "attention"
        for job in jobs:
            counts[category(job)] += 1
        projects = sorted({job["projectName"] for job in jobs if job["projectName"] != "尚未确定"})
        matched = [job for job in jobs if (status == "all" or category(job) == status)
                   and (not project or job["projectName"] == project)
                   and (not search or search in " ".join((job["jobId"], job["title"], job["text"], job["projectName"], job.get("threadId") or "")).casefold())]
        return {"jobs": matched[offset:offset + limit], "total": len(matched), "counts": counts, "projects": projects}

    def system(self):
        warnings = []
        installation = read_object(safe_path(self.root, "installation.json"), warnings)
        helper = read_object(safe_path(self.root, "hotkey-status.json"), warnings)
        helper_fields = ("version", "pid", "state", "busy", "shortcut", "registered", "hotkeyRegistered", "hotkeyStatus", "accessibilityEnabled", "accessibilityTrusted", "screenCaptureAllowed", "lastError", "lastJobId", "startedAt", "updatedAt", "lastTriggerAt", "executable")
        return {"version": VERSION, "helper": {k: helper[k] for k in helper_fields if k in helper},
                "installation": {k: installation[k] for k in ("plugin", "installedAt", "installedPath", "hotkeyApp", "launcher", "codexVersion") if k in installation},
                "warnings": warnings}


class CaptureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, data_directory, token=None, web_root=WEB_ROOT, port=0):
        self.store = JobStore(data_directory)
        self.token = token or secrets.token_urlsafe(32)
        self.web_root = Path(web_root).resolve()
        self.version = VERSION
        super().__init__(("127.0.0.1", port), CaptureHandler)
        self.origin = "http://127.0.0.1:" + str(self.server_port)


class CaptureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, format, *args):
        pass  # Paths, query strings and tokens must not enter generic access logs.

    def send_bytes(self, status, data, content_type="application/json; charset=utf-8", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status, value):
        self.send_bytes(status, json.dumps(value, ensure_ascii=False).encode())

    def validate(self, api=False, mutation=False):
        if self.headers.get("Host") not in ("127.0.0.1:" + str(self.server.server_port), "localhost:" + str(self.server.server_port)):
            raise ApiError(403, "仅允许本机访问")
        if api:
            provided = self.headers.get("Authorization", "")
            if not hmac.compare_digest(provided.encode("utf-8"), ("Bearer " + self.server.token).encode("utf-8")):
                raise ApiError(401, "需要重新从 Codex Capture 打开工作台")
        if mutation and self.headers.get("Origin") not in (None, self.server.origin):
            raise ApiError(403, "拒绝其他页面发起的操作")

    def do_GET(self):
        try:
            parsed = urlsplit(self.path)
            path = unquote(parsed.path)
            self.validate(api=path.startswith("/api/"))
            if path == "/api/health":
                return self.send_json(200, {"ok": True, "version": self.server.version, "protocolVersion": 1, "pid": os.getpid(), "dataDirectory": str(self.server.store.root), "webRoot": str(self.server.web_root), "assetsAvailable": (self.server.web_root / "index.html").is_file()})
            if path == "/api/system":
                return self.send_json(200, self.server.store.system())
            if path == "/api/jobs":
                return self.send_json(200, self.server.store.listing(parse_qs(parsed.query)))
            match = re.fullmatch(r"/api/jobs/([^/]+)(?:/(image|export))?", path)
            if match:
                job_id, operation = match.groups()
                if operation == "image":
                    image = self.server.store.image_path(job_id)
                    if image.stat().st_size > 25 * 1024 * 1024:
                        raise ApiError(413, "截图过大，请在任务文件夹查看")
                    return self.send_bytes(200, image.read_bytes(), mimetypes.guess_type(image.name)[0] or "application/octet-stream")
                detail = self.server.store.read(job_id, detail=True)
                if operation == "export":
                    return self.send_bytes(200, json.dumps(detail, ensure_ascii=False, indent=2).encode(), extra={"Content-Disposition": f'attachment; filename="codex-capture-{job_id}.json"'})
                return self.send_json(200, detail)
            if path.startswith("/api/"):
                raise ApiError(404, "找不到该接口")
            static = safe_path(self.server.web_root, "index.html" if path == "/" else path.lstrip("/"))
            if not static.is_file():
                raise ApiError(404, "找不到该页面")
            return self.send_bytes(200, static.read_bytes(), mimetypes.guess_type(static.name)[0] or "application/octet-stream")
        except ApiError as exc:
            self.send_json(exc.status, {"error": exc.message})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (ValueError, OSError):
            self.send_json(500, {"error": "读取任务记录失败，请稍后刷新"})

    def do_POST(self):
        try:
            self.validate(api=True, mutation=True)
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                raise ApiError(400, "请求长度无效")
            if length < 0 or length > 8192 or self.headers.get("Transfer-Encoding"):
                raise ApiError(413, "请求过大")
            body = self.rfile.read(length)
            if body:
                try:
                    payload = json.loads(body)
                    if not isinstance(payload, dict):
                        raise ValueError()
                except (ValueError, UnicodeError):
                    raise ApiError(400, "请求应为 JSON 对象")
            if urlsplit(self.path).path == "/api/shutdown":
                self.send_json(200, {"ok": True, "stopping": True})
                self.wfile.flush()
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            match = re.fullmatch(r"/api/jobs/([^/]+)/(cancel|open-chat)", urlsplit(self.path).path)
            if not match:
                raise ApiError(404, "找不到该操作")
            job_id, action = match.groups()
            detail = self.server.store.read(job_id, detail=True)
            if action == "cancel":
                if not detail["summary"]["isActive"]:
                    raise ApiError(409, "任务已结束，无需取消")
                marker = safe_path(self.server.store.directory(job_id), "cancel")
                marker.touch(mode=0o600)
                return self.send_json(200, {"ok": True, "cancelRequested": True, "jobId": job_id})
            if detail["summary"]["isActive"]:
                raise ApiError(409, "任务仍在后台运行，请结束后打开 Codex 对话")
            thread_id = detail["state"].get("threadId", "")
            if not isinstance(thread_id, str) or not THREAD_ID.fullmatch(thread_id):
                raise ApiError(409, "此任务尚未创建 Codex 对话")
            if sys.platform != "darwin":
                raise ApiError(409, "打开桌面对话目前仅支持 macOS")
            result = subprocess.run(["open", "-g", "codex://threads/" + thread_id], capture_output=True, timeout=15)
            if result.returncode:
                raise ApiError(502, "系统未能打开 Codex 对话")
            self.send_json(200, {"ok": True, "threadId": thread_id})
        except ApiError as exc:
            self.send_json(exc.status, {"error": exc.message})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(500, {"error": "操作失败，请查看本机日志"})


def server_health(record, data_directory=None):
    try:
        port = record["port"]
        if not isinstance(port, int) or not 1 <= port <= 65535:
            return None
        req = Request(f"http://127.0.0.1:{port}/api/health", headers={"Authorization": "Bearer " + record["token"]})
        # Never route a local bearer token through a user-configured HTTP proxy.
        with build_opener(ProxyHandler({})).open(req, timeout=1) as response:
            result = json.load(response)
        if result.get("ok") is not True or result.get("pid") != record.get("pid"):
            return None
        if data_directory is not None and result.get("dataDirectory") != str(Path(data_directory).expanduser().resolve()):
            return None
        return result
    except Exception:
        return None


def record_is_live(record, data_directory=None, web_root=None):
    health = server_health(record, data_directory)
    return compatible_health(health, web_root)


def compatible_health(health, web_root=None):
    if not health or health.get("version") != VERSION or health.get("assetsAvailable") is not True:
        return False
    return web_root is None or health.get("webRoot") == str(Path(web_root).resolve())


def endpoint_from(record):
    """Accept only a loopback port and a header-safe, generated-strength token."""
    port, token = record.get("port"), record.get("token")
    if type(port) is not int or not 1024 <= port <= 65535:
        return None
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        return None
    return {"port": port, "token": token}


def save_endpoint(root, record):
    endpoint = endpoint_from(record)
    if endpoint is not None:
        # Separate from the process record: a clean shutdown removes its PID,
        # but existing browser URLs and sessionStorage credentials remain valid.
        atomic_json(safe_path(root, "gui-endpoint.json"), endpoint)
    return endpoint


def persistent_server(root):
    endpoint = endpoint_from(read_object(safe_path(root, "gui-endpoint.json")))
    if endpoint is None:
        # Recover both an earlier installation and an uncleanly exited server.
        endpoint = endpoint_from(read_object(safe_path(root, "gui-server.json")))
    token = endpoint["token"] if endpoint else secrets.token_urlsafe(32)
    port = endpoint["port"] if endpoint else 0
    try:
        server = CaptureServer(root, token=token, port=port)
    except OSError as exc:
        if not port or exc.errno != errno.EADDRINUSE:
            raise
        # Never signal or send shutdown to whoever now owns the saved port.
        server = CaptureServer(root, token=token)
        print(f"工作台原端口 {port} 已被占用，改用 {server.server_port}；请从 Codex Capture 重新打开工作台。", file=sys.stderr, flush=True)
    try:
        save_endpoint(root, {"port": server.server_port, "token": server.token})
    except Exception:
        server.server_close()
        raise
    return server


def stop(data_directory):
    """Stop only the authenticated GUI for this exact data root; never signal a PID."""
    root = Path(data_directory).expanduser().resolve()
    record = read_object(root / "gui-server.json")
    health = server_health(record, root)
    if health is None:
        return {"stopped": False, "reason": "not_running"}
    # An older GUI deletes its process record during shutdown. Migrate first.
    save_endpoint(root, record)
    request = Request(f"http://127.0.0.1:{record['port']}/api/shutdown", data=b"{}", method="POST",
                      headers={"Authorization": "Bearer " + record["token"], "Content-Type": "application/json"})
    try:
        with build_opener(ProxyHandler({})).open(request, timeout=3) as response:
            result = json.load(response)
        if result.get("stopping") is not True:
            raise RuntimeError("旧工作台未确认退出")
    except Exception as exc:
        raise RuntimeError("无法让旧工作台安全退出，未操作任何任务进程：" + str(exc)) from exc
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if server_health(record, root) is None:
            # Wait until serve() has released its lifetime lock before starting a replacement.
            with (root / "gui-server.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    return {"stopped": True, "pid": record["pid"]}
                except BlockingIOError:
                    pass
        time.sleep(0.1)
    raise RuntimeError("工作台退出超时；未重复启动，也未中断后台任务")


def launch(data_directory, job_id=None, open_browser=True):
    root = Path(data_directory).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if job_id is not None and not JOB_ID.fullmatch(job_id):
        raise ValueError("无效 jobId")
    with (root / "gui-launch.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record_path = root / "gui-server.json"
        record = read_object(record_path)
        health = server_health(record, root)
        if health:
            save_endpoint(root, record)
        if health and not compatible_health(health, WEB_ROOT):
            stop(root)
            health = None
        if not health:
            with (root / "gui.log").open("ab") as log:
                env = os.environ.copy()
                env["CODEX_CAPTURE_DATA"] = str(root)
                process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("capture.py")), "_gui"], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True, env=env)
                # Reap it if this caller stays alive (tests or a long-running host).
                # The daemon waiter does not keep a CLI launcher open.
                threading.Thread(target=process.wait, daemon=True).start()
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                time.sleep(0.1)
                record = read_object(record_path)
                if record.get("pid") == process.pid and record_is_live(record, root, WEB_ROOT):
                    break
                if process.poll() is not None:
                    raise RuntimeError("工作台进程启动失败，请查看 gui.log")
            else:
                raise RuntimeError("工作台启动超时，请查看 gui.log")
        fragment = {"token": record["token"]}
        if job_id:
            fragment["job"] = job_id
        url = f"http://127.0.0.1:{record['port']}/#" + urlencode(fragment)
        if open_browser:
            if sys.platform == "darwin":
                subprocess.run(["open", url], check=True, timeout=15)
            else:
                import webbrowser
                webbrowser.open(url)
        return {"url": url, "pid": record["pid"], "port": record["port"], "jobId": job_id}


def serve(data_directory):
    root = Path(data_directory).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / "gui-server.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        server = persistent_server(root)
        record = {"pid": os.getpid(), "port": server.server_port, "token": server.token, "version": VERSION, "startedAt": now()}
        atomic_json(root / "gui-server.json", record)
        try:
            server.serve_forever(poll_interval=0.25)
        finally:
            server.server_close()
            current = read_object(root / "gui-server.json")
            if current.get("pid") == os.getpid():
                (root / "gui-server.json").unlink(missing_ok=True)
