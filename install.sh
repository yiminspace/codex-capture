#!/usr/bin/env bash
set -euo pipefail

capture_launch=1
case "${1:-}" in
  "") ;;
  --no-launch) capture_launch=0; shift ;;
  -h|--help)
    echo 'Usage: ./install.sh [--no-launch]'
    echo 'Install the plugin and macOS Option+S helper; --no-launch leaves the helper stopped.'
    exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac
if [ "$#" -ne 0 ]; then echo 'Unexpected arguments.' >&2; exit 2; fi

capture_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
capture_python="$(command -v python3)"
capture_codex="${CODEX_CAPTURE_CODEX_BIN:-$(command -v codex)}"
capture_tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-capture-install.XXXXXX")"
trap 'rm -rf -- "$capture_tmp"' EXIT

# Resolve binaries once so Finder launches work without a login shell or nvm.
capture_python="$("$capture_python" -c 'import sys; print(sys.executable)')"
capture_codex="$("$capture_python" - "$capture_codex" <<'PY'
import os
import shutil
import sys
path = shutil.which(sys.argv[1])
if not path:
    raise SystemExit('找不到 Codex CLI；请先安装并登录。')
print(os.path.abspath(path))
PY
)"

"$capture_python" - "$capture_root" "$capture_codex" "$capture_tmp" <<'PY'
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
if sys.version_info < (3, 10):
    raise SystemExit('Codex Capture 需要 Python 3.10 或更新版本。')
root = pathlib.Path(sys.argv[1])
if not (root / 'plugins/codex-capture/scripts/capture.py').is_file():
    raise SystemExit('插件缺少 scripts/capture.py，安装已停止。')
if not (root / 'plugins/codex-capture/scripts/gui.py').is_file() or not (root / 'plugins/codex-capture/web/index.html').is_file():
    raise SystemExit('缺少 GUI 服务或构建产物；请先在 web/ 执行 pnpm install --frozen-lockfile && pnpm build。')
version = subprocess.check_output([sys.argv[2], '--version'], text=True).strip()
match = re.search(r'(\d+)\.(\d+)\.(\d+)', version)
if not match or tuple(map(int, match.groups())) < (0, 161, 0):
    raise SystemExit(f'需要 Codex CLI 0.161.0 或更新版本；当前为 {version}。')
paths = [pathlib.Path.home() / '.local/bin/codex-capture',
         pathlib.Path.home() / '.local/bin/code-capture',
         pathlib.Path.home() / '.local/share/codex-capture/Capture.command']
for path in paths:
    if os.path.lexists(path):
        if path.is_symlink() or not path.is_file() or '# codex-capture managed launcher v1' not in path.read_text():
            raise SystemExit(f'已有非本插件入口，未覆盖：{path}')

# Reuse signed native bytes for Python/web-only updates. Re-signing an otherwise
# unchanged ad-hoc helper changes its identity and can invalidate macOS grants.
source = root / 'plugins/codex-capture'
native_files = ('native/CaptureApp.swift', 'native/Info.plist')
native_hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in native_files}
native_info = plistlib.loads((source / 'native/Info.plist').read_bytes())
app = pathlib.Path.home() / '.local/share/codex-capture/Codex Capture.app'
data = pathlib.Path(os.environ.get('CODEX_CAPTURE_DATA', str(pathlib.Path.home() / '.local/state/codex-capture'))).expanduser().resolve()

def bundle_fingerprint(bundle):
    result = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            raise ValueError('Native bundle contains a symlink')
        if path.is_file():
            result[str(path.relative_to(bundle))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result

plan = {'reuse': False, 'helperVersion': native_info['CFBundleShortVersionString'], 'sourceHashes': native_hashes}
try:
    previous = json.loads((data / 'installation.json').read_text())
    existing_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    matching_sources = all(previous.get('sha256', {}).get(name) == digest for name, digest in native_hashes.items())
    owned = not app.is_symlink() and previous.get('hotkeyApp') == str(app) and existing_info.get('CodexCaptureManaged') is True
    matching_info = existing_info == native_info and existing_info.get('CFBundleIdentifier') == 'com.yiminlab.codex-capture'
    executable = app / 'Contents/MacOS/CodexCapture'
    if matching_sources and owned and matching_info and executable.is_file() and os.access(executable, os.X_OK):
        signature = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], capture_output=True, timeout=15)
        fingerprint = bundle_fingerprint(app)
        recorded = previous.get('nativeAppFingerprint')
        # 0.4.0 and earlier recorded source hashes, managed bundle path/version,
        # and native status but no binary fingerprint. Bootstrap that record only
        # after strict signature, ownership and exact native input checks above.
        legacy_version = previous.get('helperVersion') or (previous.get('hotkeyStatus') or {}).get('version')
        matching_bundle = fingerprint == recorded if recorded is not None else legacy_version == plan['helperVersion']
        if signature.returncode == 0 and matching_bundle:
            plan.update(reuse=True, bundleFingerprint=fingerprint)
except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
    pass  # First install, changed native code or unverified bytes: build anew.
temporary = pathlib.Path(sys.argv[3])
(temporary / 'native-plan.json').write_text(json.dumps(plan))
if plan['reuse']:
    (temporary / 'reuse-native').touch()
PY

# Build before touching an existing installation. No prompts or capture occur here.
if [ "$(uname -s)" != Darwin ]; then
  echo 'The Option+S helper currently requires macOS.' >&2
  exit 1
fi
capture_app="$capture_tmp/Codex Capture.app"
if [ ! -f "$capture_tmp/reuse-native" ]; then
  mkdir -p "$capture_app/Contents/MacOS"
  cp "$capture_root/plugins/codex-capture/native/Info.plist" "$capture_app/Contents/Info.plist"
  /usr/bin/xcrun swiftc -O \
    -framework AppKit -framework Carbon -framework ApplicationServices \
    "$capture_root/plugins/codex-capture/native/CaptureApp.swift" \
    -o "$capture_app/Contents/MacOS/CodexCapture"
  /usr/bin/codesign --force --sign - "$capture_app"
  /usr/bin/codesign --verify --strict "$capture_app"
fi

"$capture_codex" plugin marketplace add "$capture_root" --json > "$capture_tmp/marketplace.json"
"$capture_codex" plugin add codex-capture@codex-capture-local --json > "$capture_tmp/install.json"

"$capture_python" - "$capture_root" "$capture_python" "$capture_codex" "$capture_tmp/install.json" "$capture_app" "$capture_launch" "$capture_tmp/native-plan.json" <<'PY'
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import time

root, python, codex, response_path, built_app, should_launch, native_plan_path = sys.argv[1:]
source = pathlib.Path(root) / 'plugins/codex-capture'
response = json.loads(pathlib.Path(response_path).read_text())
native_plan = json.loads(pathlib.Path(native_plan_path).read_text())
helper_version = native_plan['helperVersion']

def bundle_fingerprint(bundle):
    result = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            raise ValueError('Native bundle contains a symlink')
        if path.is_file():
            result[str(path.relative_to(bundle))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result

def installed_paths(value):
    if isinstance(value, dict):
        path = value.get('installedPath')
        if isinstance(path, str):
            yield pathlib.Path(path)
        for child in value.values():
            yield from installed_paths(child)
    elif isinstance(value, list):
        for child in value:
            yield from installed_paths(child)

codex_home = pathlib.Path(os.environ.get('CODEX_HOME', str(pathlib.Path.home() / '.codex')))
candidates = list(installed_paths(response))
version = json.loads((source / 'plugin.json').read_text()).get('version')
if version:
    candidates.append(codex_home / 'plugins/cache/codex-capture-local/codex-capture' / version)
candidates.append(codex_home / 'plugins/cache/codex-capture-local/codex-capture/local')
installed = None
for candidate in candidates:
    manifest = candidate / 'plugin.json'
    try:
        if json.loads(manifest.read_text()).get('name') == 'codex-capture':
            installed = candidate.resolve()
            break
    except (OSError, ValueError):
        continue
if installed is None:
    raise SystemExit('CLI 未返回可验证的插件安装目录；未创建快捷入口。')

hashes = {}
for path in sorted(source.rglob('*')):
    if not path.is_file() or '__pycache__' in path.parts or path.suffix == '.pyc':
        continue
    relative = path.relative_to(source)
    target = installed / relative
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'插件缓存未更新：{relative}。请刷新本地插件后重试安装；未创建快捷入口。')
    hashes[str(relative)] = digest

data = pathlib.Path(os.environ.get('CODEX_CAPTURE_DATA', str(pathlib.Path.home() / '.local/state/codex-capture'))).expanduser().resolve()
launcher = pathlib.Path.home() / '.local/bin/codex-capture'
command_alias = pathlib.Path.home() / '.local/bin/code-capture'
finder = pathlib.Path.home() / '.local/share/codex-capture/Capture.command'
for path in (launcher, command_alias, finder):
    path.parent.mkdir(parents=True, exist_ok=True)
launcher_text = '\n'.join([
    '#!/bin/sh',
    '# codex-capture managed launcher v1',
    'export PATH=' + shlex.quote(str(pathlib.Path(codex).parent) + ':' + str(pathlib.Path(python).parent)) + ':"${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"',
    'if [ -z "${CODEX_CAPTURE_CODEX_BIN+x}" ]; then export CODEX_CAPTURE_CODEX_BIN=' + shlex.quote(codex) + '; fi',
    'if [ -z "${CODEX_CAPTURE_DATA+x}" ]; then export CODEX_CAPTURE_DATA=' + shlex.quote(str(data)) + '; fi',
    'exec ' + shlex.quote(python) + ' ' + shlex.quote(str(installed / 'scripts/capture.py')) + ' "$@"',
    '',
])
alias_text = '\n'.join([
    '#!/bin/sh',
    '# codex-capture managed launcher v1',
    'exec ' + shlex.quote(str(launcher)) + ' "$@"',
    '',
])
finder_text = '\n'.join([
    '#!/bin/sh',
    '# codex-capture managed launcher v1',
    'exec ' + shlex.quote(str(launcher)) + ' capture "$@"',
    '',
])
for path, text in ((launcher, launcher_text), (command_alias, alias_text), (finder, finder_text)):
    temp = path.with_name(path.name + '.codex-capture-tmp')
    with temp.open('x') as stream:
        stream.write(text)
    temp.chmod(0o755)
    temp.replace(path)
data.mkdir(parents=True, exist_ok=True)
app = finder.parent / 'Codex Capture.app'
label = 'com.yiminlab.codex-capture'
agent = pathlib.Path.home() / 'Library/LaunchAgents' / (label + '.plist')
domain = f'gui/{os.getuid()}'
service = domain + '/' + label

# Only update artifacts explicitly owned by this installer.
if app.exists() or app.is_symlink():
    if app.is_symlink():
        raise SystemExit(f'拒绝替换 app 符号链接：{app}')
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    except Exception as exc:
        raise SystemExit(f'已有 app 无法验证归属，未替换：{app}: {exc}')
    if info.get('CFBundleIdentifier') != label or info.get('CodexCaptureManaged') is not True:
        raise SystemExit(f'已有非本插件 app，未替换：{app}')
if agent.exists() or agent.is_symlink():
    if agent.is_symlink():
        raise SystemExit(f'拒绝替换 LaunchAgent 符号链接：{agent}')
    info = plistlib.loads(agent.read_bytes())
    if info.get('Label') != label or info.get('CodexCaptureManaged') is not True:
        raise SystemExit(f'已有非本插件 LaunchAgent，未替换：{agent}')
if native_plan['reuse'] and bundle_fingerprint(app) != native_plan['bundleFingerprint']:
    raise SystemExit('原生助手在检查后发生变化，未停止或替换。请检查后重试。')

# A manually reopened app can run outside launchd. Recognize that exact owned
# executable before stopping it; never kill by a broad process-name match.
previous_pid = None
status_path = data / 'hotkey-status.json'
try:
    previous_status = json.loads(status_path.read_text())
    candidate_pid = int(previous_status.get('pid', 0))
    expected_executable = str(app / 'Contents/MacOS/CodexCapture')
    command = subprocess.run(['/bin/ps', '-p', str(candidate_pid), '-o', 'comm='], capture_output=True, text=True)
    if candidate_pid > 1 and previous_status.get('executable') == expected_executable and command.stdout.strip() == expected_executable:
        if previous_status.get('busy'):
            raise SystemExit('助手正在截图或提交，请完成或取消当前输入后再更新。')
        previous_pid = candidate_pid
except (OSError, ValueError, TypeError):
    pass
running = subprocess.run(['/bin/launchctl', 'print', service], capture_output=True)
if running.returncode == 0:
    subprocess.run(['/bin/launchctl', 'bootout', service], check=True)
if previous_pid:
    # Check the executable again after bootout in case launchd already reaped it.
    command = subprocess.run(['/bin/ps', '-p', str(previous_pid), '-o', 'comm='], capture_output=True, text=True)
    if command.stdout.strip() == str(app / 'Contents/MacOS/CodexCapture'):
        os.kill(previous_pid, signal.SIGTERM)
        stop_deadline = time.monotonic() + 5
        while time.monotonic() < stop_deadline:
            try:
                os.kill(previous_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            raise SystemExit('旧助手未退出，保留 app 未替换。请退出 Codex Capture 后重试。')

staged = app.with_name(app.name + '.installing')
backup = app.with_name(app.name + '.previous')
if staged.exists() or backup.exists():
    raise SystemExit('发现未完成的 app 安装；保留旧文件，请检查 .installing/.previous 后重试。')
if not native_plan['reuse']:
    shutil.copytree(built_app, staged)
    try:
        if app.exists():
            app.rename(backup)
        staged.rename(app)
    except BaseException:
        if backup.exists() and not app.exists():
            backup.rename(app)
        raise
    if backup.exists():
        shutil.rmtree(backup)

agent.parent.mkdir(parents=True, exist_ok=True)
agent_info = {
    'Label': label,
    'CodexCaptureManaged': True,
    'AssociatedBundleIdentifiers': [label],
    'ProgramArguments': [str(app / 'Contents/MacOS/CodexCapture')],
    'EnvironmentVariables': {
        'CODEX_CAPTURE_DATA': str(data),
        'CODEX_CAPTURE_LAUNCHER': str(launcher),
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    },
    'RunAtLoad': True,
    'KeepAlive': {'SuccessfulExit': False},
    'ProcessType': 'Interactive',
    'LimitLoadToSessionType': 'Aqua',
    'ThrottleInterval': 10,
    'StandardOutPath': str(data / 'hotkey.stdout.log'),
    'StandardErrorPath': str(data / 'hotkey.stderr.log'),
}
agent_tmp = agent.with_suffix('.plist.installing')
if agent_tmp.exists():
    raise SystemExit(f'发现未完成的 LaunchAgent 安装：{agent_tmp}')
agent_tmp.write_bytes(plistlib.dumps(agent_info))
agent_tmp.chmod(0o600)
agent_tmp.replace(agent)

hotkey_status = None
if should_launch == '1':
    # Remove only our previous readiness record, not user task records.
    if status_path.exists():
        status_path.unlink()
    # Immediately after bootout, launchd can briefly return exit 5 even though
    # the service is absent. Retry that case only, without elevation or unloads.
    for attempt in range(4):
        bootstrap = subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(agent)], capture_output=True, text=True)
        if bootstrap.returncode == 0:
            break
        registered = subprocess.run(['/bin/launchctl', 'print', service], capture_output=True)
        if registered.returncode == 0:
            break  # The readiness check below validates the actual helper.
        if bootstrap.returncode != 5 or attempt == 3:
            raise SystemExit('助手启动失败：' + bootstrap.stderr.strip())
        time.sleep(0.5)
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            candidate_status = json.loads(status_path.read_text())
            if candidate_status.get('pid') and candidate_status.get('version') == helper_version:
                os.kill(int(candidate_status['pid']), 0)
                hotkey_status = candidate_status
                break
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    if not hotkey_status:
        raise SystemExit('助手已启动但未返回就绪状态；请检查 hotkey.stderr.log。')

# A cache upgrade may remove the old GUI's static assets while leaving its
# process alive. Refresh an already-running workbench from this installation;
# gui.launch preserves its endpoint and only replaces the authenticated GUI.
sys.path.insert(0, str(installed / 'scripts'))
import gui
gui_status = None
if gui.server_health(gui.read_object(data / 'gui-server.json'), data):
    running_gui = gui.launch(data, open_browser=False)
    gui_status = {key: running_gui[key] for key in ('pid', 'port')}

record = {
    'plugin': 'codex-capture@codex-capture-local',
    'installedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'sourceRoot': root,
    'installedPath': str(installed),
    'launcher': str(launcher),
    'commandAlias': str(command_alias),
    'finderLauncher': str(finder),
    'hotkeyApp': str(app),
    'launchAgent': str(agent),
    'hotkeyStatus': hotkey_status,
    'helperVersion': helper_version,
    'nativeReused': native_plan['reuse'],
    'workbench': gui_status,
    'nativeSourceHashes': native_plan['sourceHashes'],
    'nativeAppFingerprint': bundle_fingerprint(app),
    'python': python,
    'codex': codex,
    'codexVersion': subprocess.check_output([codex, '--version'], text=True).strip(),
    'sha256': hashes,
}
(data / 'installation.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(record, ensure_ascii=False, indent=2))
if should_launch == '1' and hotkey_status.get('registered') is not True:
    raise SystemExit('插件已安装，但 Option+S 未注册成功；请查看 hotkeyStatus/lastError。助手菜单仍可截图。')
PY
