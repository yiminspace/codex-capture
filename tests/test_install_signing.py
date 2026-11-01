"""Installer identity and migration gates with isolated files and mocked OS tools."""
import ast
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
BLOCKS = re.findall(r"<<'PY'\n(.*?)\nPY", (ROOT / 'install.sh').read_text(), re.DOTALL)
PREFLIGHT = next(block for block in BLOCKS if "'sourceHashes'" in block and "native-plan.json" in block)
INSTALL = next(block for block in BLOCKS if 'screen_capture_reset = None' in block)
RESET_NODE = next(node for node in ast.parse(INSTALL).body
                  if isinstance(node, ast.If) and "signingMigrationRequired" in ast.get_source_segment(INSTALL, node.test))
RESET = ast.get_source_segment(INSTALL, RESET_NODE)
REFRESH = INSTALL[INSTALL.index('# A cache upgrade'):INSTALL.index('\nrecord = {')]
APP_ID = 'com.yiminlab.codex-capture'


class SigningFailure(RuntimeError):
    pass


class RuntimeSelectionTests(unittest.TestCase):
    def test_runtime_selection_is_published_before_gui_restart_in_both_directions(self):
        for editable in ('0', '1'):
            with self.subTest(editable=editable), tempfile.TemporaryDirectory(prefix='capture-install-runtime-') as tmp:
                data = Path(tmp)
                runtime = data / ('source' if editable == '1' else 'cache')
                path = data / 'installation.json'
                path.write_text(json.dumps({'installMode': 'cached' if editable == '1' else 'editable', 'runtimePath': 'previous', 'retained': 'metadata'}))
                observed = []
                gui = types.ModuleType('gui')
                gui.read_object = lambda _path: {}
                gui.server_health = lambda _record, _root: True

                def launch(_data, open_browser):
                    observed.append(json.loads(path.read_text()))
                    return {'pid': 123, 'port': 54321}

                gui.launch = launch
                environment = {'data': data, 'root': str(data / 'repository'), 'runtime': runtime,
                               'editable': editable, 'json': json, 'sys': types.SimpleNamespace(path=[])}
                with mock.patch.dict(sys.modules, {'gui': gui}):
                    exec(compile(REFRESH, 'installer-refresh-fixture', 'exec'), environment)
                self.assertEqual(len(observed), 1)
                self.assertEqual(observed[0]['installMode'], 'editable' if editable == '1' else 'cached')
                self.assertEqual(observed[0]['runtimePath'], str(runtime))
                self.assertEqual(observed[0]['retained'], 'metadata')
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class InstallerSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='capture-install-signing-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / 'home'
        self.source = self.base / 'source'
        self.output = self.base / 'output'
        self.output.mkdir()
        self.plugin = self.source / 'plugins/codex-capture'
        for name in ('scripts/capture.py', 'scripts/gui.py', 'web/index.html', 'native/CaptureApp.swift'):
            path = self.plugin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic fixture\n')
        self.info = {'CFBundleIdentifier': APP_ID, 'CFBundleShortVersionString': '1.2.3', 'CodexCaptureManaged': True}
        (self.plugin / 'native/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.app = self.home / '.local/share/codex-capture/Codex Capture.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        binary = self.app / 'Contents/MacOS/CodexCapture'
        binary.write_text('synthetic executable\n')
        binary.chmod(0o700)
        self.data = self.base / 'data'
        self.data.mkdir()
        record = {'hotkeyApp': str(self.app), 'helperVersion': '1.2.3',
                  'sha256': {name: hashlib.sha256((self.plugin / name).read_bytes()).hexdigest()
                             for name in ('native/CaptureApp.swift', 'native/Info.plist')},
                  'nativeAppFingerprint': {str(path.relative_to(self.app)): hashlib.sha256(path.read_bytes()).hexdigest()
                                           for path in self.app.rglob('*') if path.is_file()}}
        (self.data / 'installation.json').write_text(json.dumps(record))
        self.signer = types.ModuleType('native_signing')
        self.signer.APP_ID = APP_ID
        self.signer.SigningError = SigningFailure
        self.signer.ensure = mock.Mock(return_value={'identitySHA1': 'A' * 40, 'designatedRequirement': 'fixture pinned certificate'})
        self.signer.verify = mock.Mock()

    def preflight(self):
        original_path = list(sys.path)
        self.addCleanup(lambda: sys.path.__setitem__(slice(None), original_path))
        with mock.patch.object(Path, 'home', return_value=self.home), \
             mock.patch.dict(sys.modules, {'native_signing': self.signer}), \
             mock.patch.dict(os.environ, {'CODEX_CAPTURE_DATA': str(self.data), 'CODEX_CAPTURE_SIGNING_IDENTITY': ''}), \
             mock.patch.object(sys, 'argv', ['fixture', str(self.source), '/fixture/codex', str(self.output)]), \
             mock.patch.object(subprocess, 'check_output', return_value='codex-cli 0.161.0'), \
             mock.patch.object(subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)):
            exec(compile(PREFLIGHT, 'installer-preflight-fixture', 'exec'), {})
        return json.loads((self.output / 'native-plan.json').read_text())

    def test_unchanged_native_bytes_reuse_only_after_fixed_signature_verification(self):
        plan = self.preflight()
        self.assertTrue(plan['reuse'])
        self.signer.verify.assert_called_once_with(self.app, plan['signing'])
        self.assertEqual(self.signer.ensure.call_args.kwargs['previous_app'], self.app)

    def test_unchanged_adhoc_bytes_cannot_skip_the_signing_migration(self):
        self.signer.verify.side_effect = SigningFailure('old ad-hoc identity')
        self.assertFalse(self.preflight()['reuse'])
        self.assertFalse((self.output / 'reuse-native').exists())

    def test_changed_native_source_forces_rebuild_with_same_pinned_identity(self):
        (self.plugin / 'native/CaptureApp.swift').write_text('changed synthetic native fixture\n')
        plan = self.preflight()
        self.assertFalse(plan['reuse'])
        self.assertEqual(plan['signing']['identitySHA1'], 'A' * 40)

    def test_unavailable_identity_stops_before_a_replacement_plan_exists(self):
        self.signer.ensure.side_effect = SigningFailure('missing pinned identity')
        with self.assertRaises(SigningFailure):
            self.preflight()
        self.assertFalse((self.output / 'native-plan.json').exists())
        self.assertTrue((self.app / 'Contents/MacOS/CodexCapture').is_file())

    def test_unmanaged_app_never_initializes_a_signing_identity(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'example.other'}))
        with self.assertRaises(SystemExit):
            self.preflight()
        self.signer.ensure.assert_not_called()

    def test_normal_updates_never_reset_screen_capture_authorization(self):
        runner = mock.Mock()
        environment = {'native_plan': {'signingMigrationRequired': False}, 'screen_capture_reset': None,
                       'subprocess': types.SimpleNamespace(run=runner), 'label': APP_ID}
        exec(compile(RESET, 'installer-reset-fixture', 'exec'), environment)
        runner.assert_not_called()
        self.assertIsNone(environment['screen_capture_reset'])

    def test_one_time_migration_resets_only_this_apps_screen_capture_permission(self):
        runner = mock.Mock(return_value=types.SimpleNamespace(returncode=0, stderr=''))
        environment = {'native_plan': {'signingMigrationRequired': True}, 'screen_capture_reset': None,
                       'subprocess': types.SimpleNamespace(run=runner), 'label': APP_ID}
        exec(compile(RESET, 'installer-reset-fixture', 'exec'), environment)
        self.assertEqual(runner.call_args.args[0], ['/usr/bin/tccutil', 'reset', 'ScreenCapture', APP_ID])
        self.assertEqual(environment['screen_capture_reset'], {'attempted': True, 'exitCode': 0})

    def test_reset_timeout_is_recorded_without_aborting_new_helper_startup(self):
        runner = mock.Mock(side_effect=subprocess.TimeoutExpired('tccutil', 15))
        environment = {'native_plan': {'signingMigrationRequired': True}, 'screen_capture_reset': None,
                       'subprocess': types.SimpleNamespace(run=runner, TimeoutExpired=subprocess.TimeoutExpired), 'label': APP_ID}
        exec(compile(RESET, 'installer-reset-fixture', 'exec'), environment)
        self.assertTrue(environment['screen_capture_reset']['attempted'])
        self.assertIsNone(environment['screen_capture_reset']['exitCode'])


if __name__ == '__main__':
    unittest.main()
