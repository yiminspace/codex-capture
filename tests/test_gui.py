"""Workbench checks use isolated records and local HTTP, never real chats."""
import contextlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SCRIPT = Path(__file__).resolve().parents[1] / "plugins/codex-capture/scripts/gui.py"
SPEC = importlib.util.spec_from_file_location("capture_gui_test", SCRIPT)
gui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gui)
JOB = "12345678-abcd-1234-abcd-123456789abc"
THREAD = "abcdef12-abcd-1234-abcd-123456789abc"


def fixture(root, job_id=JOB, **updates):
    directory = root / "jobs" / job_id
    directory.mkdir(parents=True, exist_ok=True)
    state = {"jobId": job_id, "phase": "completed", "createdAt": "2025-01-01T08:00:00Z", "startedAt": "2025-01-01T08:00:01Z", "updatedAt": "2025-01-01T08:00:11Z", "completedAt": "2025-01-01T08:00:11Z", "project": {"name": "sample-notes"}, "threadId": THREAD, "followupAttempts": 1}
    state.update(updates)
    gui.atomic_json(directory / "state.json", state)
    gui.atomic_json(directory / "request.json", {"text": "便签需要标签编辑入口", "image": str(directory / "screenshot.png"), "context": {"app": {"name": "Browser"}}})
    gui.atomic_json(directory / "route.json", {"title": "示例便签标签编辑", "reason": "示例窗口与虚构便签项目匹配", "confidence": 0.99})
    (directory / "screenshot.png").write_bytes(b"png-fixture")
    return directory


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = gui.JobStore(self.root)
        self.directory = fixture(self.root)

    def test_existing_history_includes_images_context_routing_and_duration(self):
        detail = self.store.read(JOB, detail=True)
        self.assertEqual(detail["summary"]["elapsedSeconds"], 10)
        self.assertEqual(detail["summary"]["projectName"], "sample-notes")
        self.assertTrue(detail["summary"]["hasImage"])
        self.assertEqual(detail["request"]["context"]["app"]["name"], "Browser")
        self.assertEqual(detail["route"]["confidence"], 0.99)
        self.assertEqual(detail["eventsTotal"], 0)

    def test_dead_worker_is_derived_interrupted_without_changing_disk(self):
        state = gui.read_object(self.directory / "state.json")
        state.update(phase="running_initial", workerPid=12345)
        gui.atomic_json(self.directory / "state.json", state)
        before = (self.directory / "state.json").read_bytes()
        with mock.patch.object(gui, "worker_alive", return_value=False):
            detail = self.store.read(JOB, detail=True)
        self.assertEqual(detail["summary"]["phase"], "running_initial")
        self.assertEqual(detail["summary"]["derivedPhase"], "interrupted")
        self.assertFalse(detail["summary"]["isActive"])
        self.assertTrue(detail["warnings"])
        self.assertEqual(before, (self.directory / "state.json").read_bytes())

    def test_pid_reuse_is_not_mistaken_for_worker(self):
        with mock.patch.object(gui.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "python unrelated.py")):
            self.assertFalse(gui.worker_alive({"workerPid": 123}, JOB))
        with mock.patch.object(gui.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, f"python /cache/capture.py _worker {JOB}")):
            self.assertTrue(gui.worker_alive({"workerPid": 123}, JOB))

    def test_pagination_search_and_filter_have_true_counts(self):
        fixture(self.root, "22345678-abcd", phase="failed", project={"name": "other"})
        fixture(self.root, "32345678-abcd", phase="running_initial", workerPid=123)
        with mock.patch.object(gui, "worker_alive", return_value=True):
            result = self.store.listing({"limit": ["1"]})
            filtered = self.store.listing({"status": ["attention"], "project": ["other"]})
            searched = self.store.listing({"q": ["标签"]})
        self.assertEqual(len(result["jobs"]), 1)
        self.assertEqual(result["total"], 3)
        self.assertEqual(result["counts"], {"all": 3, "active": 1, "completed": 1, "attention": 1})
        self.assertEqual(filtered["total"], 1)
        self.assertEqual(searched["total"], 3)
        self.assertEqual(result["projects"], ["other", "sample-notes"])

    def test_corrupt_record_does_not_remove_other_jobs(self):
        fixture(self.root, "22345678-abcd")
        (self.directory / "state.json").write_text("{broken")
        result = self.store.listing({})
        self.assertEqual(result["total"], 2)
        corrupt = next(job for job in result["jobs"] if job["jobId"] == JOB)
        self.assertEqual(corrupt["derivedPhase"], "unknown")
        self.assertGreater(corrupt["warningCount"], 0)

    def test_wrong_json_field_types_do_not_break_listing(self):
        gui.atomic_json(self.directory / "state.json", {"phase": [], "createdAt": {}, "threadId": {}})
        result = self.store.listing({"q": ["标签"]})
        self.assertEqual(result["total"], 1)
        self.assertEqual(result["jobs"][0]["derivedPhase"], "unknown")
        self.assertIsNone(result["jobs"][0]["threadId"])

    def test_event_cache_invalidates_when_worker_appends(self):
        path = self.directory / "events.jsonl"
        path.write_text('{"method":"turn/started"}\n')
        self.assertEqual(gui.read_events(path)[1], 1)
        with mock.patch.object(Path, "open", side_effect=AssertionError("cached file should not reopen")):
            self.assertEqual(gui.read_events(path)[1], 1)
        with path.open("a") as stream:
            stream.write('{"method":"turn/completed"}\n')
        events, total, malformed = gui.read_events(path)
        self.assertEqual((total, malformed), (2, 0))
        self.assertEqual(events[-1]["method"], "turn/completed")

    def test_event_tail_reports_truncation_and_tool_failures(self):
        rows = [{"itemType": "commandExecution", "status": "failed" if i == 350 else "completed", "at": i} for i in range(400)]
        rows.append({"itemType": "reasoning", "text": "hidden reasoning", "summary": "hidden"})
        (self.directory / "events.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n{partial")
        (self.directory / "worker.log").write_text("a" * 40000)
        detail = self.store.read(JOB, detail=True)
        self.assertEqual(len(detail["events"]), 300)
        self.assertEqual(detail["eventsTotal"], 402)
        self.assertTrue(detail["eventsTruncated"])
        self.assertNotIn("text", detail["events"][-1])
        self.assertTrue(any("工具执行失败" in warning for warning in detail["warnings"]))
        self.assertTrue(detail["logs"]["worker.log"].startswith("[仅显示最后 32 KiB]"))

    def test_oversized_event_line_does_not_exhaust_memory_or_hide_later_rows(self):
        (self.directory / "events.jsonl").write_bytes(b"x" * 300000 + b'\n{"method":"turn/completed"}\n')
        detail = self.store.read(JOB, detail=True)
        self.assertEqual(detail["eventsTotal"], 2)
        self.assertEqual(detail["events"][0]["method"], "turn/completed")
        self.assertTrue(detail["warnings"])

    def test_paths_and_symlink_images_cannot_escape_job(self):
        outside = self.root / "secret.png"
        outside.write_bytes(b"secret")
        (self.directory / "screenshot.png").unlink()
        (self.directory / "screenshot.png").symlink_to(outside)
        request = gui.read_object(self.directory / "request.json")
        request["image"] = str(outside)
        gui.atomic_json(self.directory / "request.json", request)
        self.assertIsNone(self.store.image_path(JOB, optional=True))
        for unsafe in ("../secret", "foo/bar", "/etc/passwd"):
            with self.assertRaises(gui.ApiError):
                self.store.directory(unsafe)
        (self.root / "jobs" / "22345678-abcd").symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(gui.ApiError):
            self.store.directory("22345678-abcd")

    def test_system_omits_installer_auth_secrets(self):
        gui.atomic_json(self.root / "installation.json", {"plugin": "capture", "token": "secret", "apiKey": "secret", "sha256": {}})
        gui.atomic_json(self.root / "hotkey-status.json", {"registered": True, "token": "secret"})
        system = self.store.system()
        self.assertEqual(system["installation"], {"plugin": "capture"})
        self.assertTrue(system["helper"]["registered"])
        self.assertNotIn("token", system["helper"])


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.directory = fixture(self.root)
        self.web = self.root / "web"
        self.web.mkdir()
        (self.web / "assets").mkdir()
        (self.web / "index.html").write_text("<main>Capture</main>")
        (self.web / "assets/app.js").write_text("console.log('fixture')")
        self.server = gui.CaptureServer(self.root, token="fixture-token", web_root=self.web)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.cleanup_server)
        self.url = self.server.origin

    def cleanup_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, path, method="GET", auth=True, headers=None, data=None):
        request_headers = dict(headers or {})
        if auth:
            request_headers.setdefault("Authorization", "Bearer fixture-token")
        if method == "POST" and data is None:
            data = b"{}"
        req = Request(self.url + path, method=method, headers=request_headers, data=data)
        try:
            with urlopen(req, timeout=3) as response:
                return response.status, response.read(), response.headers
        except HTTPError as error:
            return error.code, error.read(), error.headers

    def test_api_auth_host_and_mutation_origin_are_enforced(self):
        self.assertEqual(self.request("/api/jobs", auth=False)[0], 401)
        self.assertEqual(self.request("/api/jobs", headers={"Authorization": "Bearer wrong"})[0], 401)
        self.assertEqual(self.request("/api/jobs", headers={"Host": "evil.example"})[0], 403)
        self.assertEqual(self.request(f"/api/jobs/{JOB}/cancel", method="POST", headers={"Origin": "https://evil.example"})[0], 403)
        self.assertEqual(self.request("/api/jobs")[0], 200)

    def test_static_assets_work_but_traversal_and_symlinks_do_not(self):
        self.assertEqual(self.request("/", auth=False)[0], 200)
        code, _, headers = self.request("/assets/app.js", auth=False)
        self.assertEqual(code, 200)
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        (self.web / "escape.txt").symlink_to(self.directory / "state.json")
        self.assertEqual(self.request("/escape.txt", auth=False)[0], 404)
        self.assertEqual(self.request("/%2e%2e/jobs/" + JOB + "/state.json", auth=False)[0], 404)

    def test_image_and_export_are_authenticated_and_export_is_download(self):
        self.assertEqual(self.request(f"/api/jobs/{JOB}/image", auth=False)[0], 401)
        code, image, _ = self.request(f"/api/jobs/{JOB}/image")
        self.assertEqual((code, image), (200, b"png-fixture"))
        code, body, headers = self.request(f"/api/jobs/{JOB}/export")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["jobId"], JOB)
        self.assertIn("attachment", headers["Content-Disposition"])
        self.assertNotIn("fixture-token", body.decode())

    def test_cancel_requires_active_worker_and_only_sets_marker(self):
        self.assertEqual(self.request(f"/api/jobs/{JOB}/cancel", method="POST")[0], 409)
        state = gui.read_object(self.directory / "state.json")
        state.update(phase="running_initial", workerPid=123)
        gui.atomic_json(self.directory / "state.json", state)
        with mock.patch.object(gui, "worker_alive", return_value=True):
            code, body, _ = self.request(f"/api/jobs/{JOB}/cancel", method="POST", headers={"Origin": self.url})
        self.assertEqual(code, 200)
        self.assertTrue(json.loads(body)["cancelRequested"])
        self.assertTrue((self.directory / "cancel").exists())
        self.assertEqual(gui.read_object(self.directory / "state.json")["phase"], "running_initial")

    def test_open_chat_refuses_active_writer_and_uses_validated_thread(self):
        state = gui.read_object(self.directory / "state.json")
        state.update(phase="running_initial", workerPid=123)
        gui.atomic_json(self.directory / "state.json", state)
        with mock.patch.object(gui, "worker_alive", return_value=True), mock.patch.object(gui.subprocess, "run") as opened:
            self.assertEqual(self.request(f"/api/jobs/{JOB}/open-chat", method="POST")[0], 409)
            opened.assert_not_called()
        with mock.patch.object(gui, "worker_alive", return_value=False), mock.patch.object(gui.sys, "platform", "darwin"), mock.patch.object(gui.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as opened:
            self.assertEqual(self.request(f"/api/jobs/{JOB}/open-chat", method="POST")[0], 200)
            opened.assert_called_once_with(["open", "-g", "codex://threads/" + THREAD], capture_output=True, timeout=15)
        state.update(phase="completed", threadId="../bad")
        gui.atomic_json(self.directory / "state.json", state)
        self.assertEqual(self.request(f"/api/jobs/{JOB}/open-chat", method="POST")[0], 409)

    def test_health_probe_uses_token_and_matching_pid_version(self):
        record = {"port": self.server.server_port, "token": self.server.token, "pid": gui.os.getpid()}
        self.assertTrue(gui.record_is_live(record))
        self.assertFalse(gui.record_is_live({**record, "token": "wrong"}))
        self.assertFalse(gui.record_is_live({**record, "pid": -1}))

    def test_shutdown_requires_auth_and_scope_matches_data_directory(self):
        record = {"port": self.server.server_port, "token": self.server.token, "pid": gui.os.getpid()}
        gui.atomic_json(self.root / "gui-server.json", record)
        self.assertEqual(self.request("/api/shutdown", method="POST", auth=False)[0], 401)
        other_root = self.root / "other-data"
        other_root.mkdir()
        gui.atomic_json(other_root / "gui-server.json", record)
        self.assertFalse(gui.stop(other_root)["stopped"])
        self.assertTrue(gui.record_is_live(record))

    def test_launch_reuses_healthy_server_and_never_starts_worker_or_browser_when_disabled(self):
        record = {"port": self.server.server_port, "token": self.server.token, "pid": gui.os.getpid()}
        gui.atomic_json(self.root / "gui-server.json", record)
        with mock.patch.object(gui, "WEB_ROOT", self.web), mock.patch.object(gui.subprocess, "Popen") as start, mock.patch.object(gui.subprocess, "run") as opened:
            result = gui.launch(self.root, JOB, open_browser=False)
        start.assert_not_called()
        opened.assert_not_called()
        self.assertIn("#token=fixture-token&job=" + JOB, result["url"])
        self.assertEqual((self.root / "gui-server.json").stat().st_mode & 0o777, 0o600)

    def test_invalid_json_and_body_limits_do_not_cancel(self):
        self.assertEqual(self.request(f"/api/jobs/{JOB}/cancel", method="POST", data=b"[]")[0], 400)
        self.assertEqual(self.request(f"/api/jobs/{JOB}/cancel", method="POST", data=b"x" * 9000)[0], 413)
        self.assertFalse((self.directory / "cancel").exists())


class ProcessLifecycleTests(unittest.TestCase):
    def test_upgrade_stops_authenticated_old_gui_and_starts_current_without_touching_jobs(self):
        with tempfile.TemporaryDirectory(prefix="capture-gui-upgrade-") as tmp:
            root = Path(tmp)
            directory = fixture(root)
            before = (directory / "state.json").read_bytes()
            code = "import importlib.util,sys; s=importlib.util.spec_from_file_location('old_gui',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.VERSION='0.2.99'; m.serve(sys.argv[2])"
            old = subprocess.Popen([sys.executable, "-c", code, str(SCRIPT), str(root)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                record = {}
                while time.monotonic() < deadline:
                    record = gui.read_object(root / "gui-server.json")
                    if gui.server_health(record, root):
                        break
                    time.sleep(.05)
                self.assertEqual(gui.server_health(record, root)["version"], "0.2.99")
                # Simulate the legacy GUI, which kept only its transient record.
                (root / "gui-endpoint.json").unlink()
                current = gui.launch(root, open_browser=False)
                self.assertNotEqual(current["pid"], old.pid)
                old.wait(timeout=3)
                self.assertEqual(old.returncode, 0)
                new_record = gui.read_object(root / "gui-server.json")
                self.assertTrue(gui.record_is_live(new_record, root))
                self.assertEqual((new_record["port"], new_record["token"]), (record["port"], record["token"]))
                self.assertEqual(before, (directory / "state.json").read_bytes())
                self.assertFalse((directory / "cancel").exists())
                self.assertTrue(gui.stop(root)["stopped"])
            finally:
                with contextlib.suppress(Exception):
                    gui.stop(root)
                if old.poll() is None:
                    old.terminate()
                old.wait(timeout=3)

    def test_restart_preserves_existing_browser_url_token_and_job_records(self):
        with tempfile.TemporaryDirectory(prefix="capture-gui-restart-") as tmp:
            root = Path(tmp)
            directory = fixture(root)
            original_job = (directory / "state.json").read_bytes()
            try:
                first = gui.launch(root, JOB, open_browser=False)
                record = gui.read_object(root / "gui-server.json")
                self.assertTrue(gui.stop(root)["stopped"])
                self.assertFalse((root / "gui-server.json").exists())
                self.assertEqual(gui.read_object(root / "gui-endpoint.json"), gui.endpoint_from(record))
                second = gui.launch(root, JOB, open_browser=False)
                self.assertEqual(second["url"], first["url"])
                self.assertNotEqual(second["pid"], first["pid"])
                request = Request(f"http://127.0.0.1:{record['port']}/api/jobs/{JOB}", headers={"Authorization": "Bearer " + record["token"]})
                with urlopen(request, timeout=3) as response:
                    self.assertEqual(json.load(response)["jobId"], JOB)
                self.assertEqual((root / "gui-endpoint.json").stat().st_mode & 0o777, 0o600)
                self.assertEqual((directory / "state.json").read_bytes(), original_job)
            finally:
                gui.stop(root)

    def test_same_version_changed_installation_or_removed_assets_restarts_gui(self):
        for remove_assets in (False, True):
            with self.subTest(remove_assets=remove_assets), tempfile.TemporaryDirectory(prefix="capture-gui-install-") as tmp:
                root = Path(tmp) / "data"
                root.mkdir()
                previous = Path(tmp) / "previous-install"
                (previous / "scripts").mkdir(parents=True)
                (previous / "web").mkdir()
                (previous / "web/index.html").write_text("old assets")
                shutil.copyfile(SCRIPT, previous / "scripts/gui.py")
                code = "import importlib.util,sys; s=importlib.util.spec_from_file_location('old_gui',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.serve(sys.argv[2])"
                old = subprocess.Popen([sys.executable, "-c", code, str(previous / "scripts/gui.py"), str(root)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        record = gui.read_object(root / "gui-server.json")
                        if gui.server_health(record, root):
                            break
                        time.sleep(.05)
                    self.assertEqual(gui.server_health(record, root)["version"], gui.VERSION)
                    if remove_assets:
                        shutil.rmtree(previous / "web")
                        self.assertFalse(gui.server_health(record, root)["assetsAvailable"])
                    current = gui.launch(root, open_browser=False)
                    old.wait(timeout=3)
                    self.assertNotEqual(current["pid"], old.pid)
                    self.assertEqual(current["port"], record["port"])
                    live = gui.read_object(root / "gui-server.json")
                    self.assertTrue(gui.record_is_live(live, root, gui.WEB_ROOT))
                    with urlopen(f"http://127.0.0.1:{current['port']}/", timeout=3) as response:
                        self.assertEqual(response.status, 200)
                finally:
                    with contextlib.suppress(Exception):
                        gui.stop(root)
                    if old.poll() is None:
                        old.terminate()
                    old.wait(timeout=3)


class EndpointTests(unittest.TestCase):
    def test_occupied_saved_port_falls_back_without_stopping_owner_or_rotating_token(self):
        with tempfile.TemporaryDirectory(prefix="capture-gui-occupied-") as tmp:
            root = Path(tmp)
            owner = gui.CaptureServer(root, token="owner-token")
            token = "saved-token-" + "a" * 32
            gui.atomic_json(root / "gui-endpoint.json", {"port": owner.server_port, "token": token})
            try:
                with mock.patch.object(gui.sys, "stderr") as stderr:
                    replacement = gui.persistent_server(root)
                try:
                    self.assertNotEqual(replacement.server_port, owner.server_port)
                    self.assertEqual(replacement.token, token)
                    self.assertGreaterEqual(owner.fileno(), 0)
                    self.assertEqual(gui.read_object(root / "gui-endpoint.json"), {"port": replacement.server_port, "token": token})
                    self.assertTrue(stderr.write.called)
                finally:
                    replacement.server_close()
            finally:
                owner.server_close()

    def test_malformed_endpoint_is_replaced_with_private_valid_record(self):
        for record in ("{broken", '{"port": true, "token": "short"}', json.dumps({"port": 50000, "token": "a" * 32 + "\r\n"}), json.dumps({"port": 80, "token": "a" * 32})):
            with self.subTest(record=record), tempfile.TemporaryDirectory(prefix="capture-gui-invalid-") as tmp:
                root = Path(tmp)
                (root / "gui-endpoint.json").write_text(record)
                server = gui.persistent_server(root)
                try:
                    endpoint = gui.read_object(root / "gui-endpoint.json")
                    self.assertIsNotNone(gui.endpoint_from(endpoint))
                    self.assertEqual(endpoint, {"port": server.server_port, "token": server.token})
                    self.assertEqual((root / "gui-endpoint.json").stat().st_mode & 0o777, 0o600)
                finally:
                    server.server_close()

    def test_crashed_legacy_server_record_recovers_endpoint(self):
        with tempfile.TemporaryDirectory(prefix="capture-gui-legacy-") as tmp:
            root = Path(tmp)
            previous = gui.CaptureServer(root)
            endpoint = {"port": previous.server_port, "token": previous.token}
            previous.server_close()
            gui.atomic_json(root / "gui-server.json", {**endpoint, "pid": -1, "version": "0.4.0"})
            server = gui.persistent_server(root)
            try:
                self.assertEqual(gui.read_object(root / "gui-endpoint.json"), endpoint)
                self.assertEqual(server.server_port, endpoint["port"])
            finally:
                server.server_close()


if __name__ == "__main__":
    unittest.main()
