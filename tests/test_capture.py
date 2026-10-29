"""Offline protocol and lifecycle checks; no real Codex model or chat is started."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "plugins/codex-capture/scripts/capture.py"
SPEC = importlib.util.spec_from_file_location("capture_under_test", SCRIPT)
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)
TEST_FOLLOWUP = "Review this task’s changes and report the result."


FAKE_SERVER = r'''
import json, os, sys
def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if not method:
        continue
    ident = message.get("id")
    params = message.get("params", {})
    if method == "initialize":
        if os.environ.get("FAKE_INIT_ERROR"):
            send({"id": ident, "error": {"code": -32000, "message": "handshake failed"}})
        else:
            send({"id": ident, "result": {"userAgent": "offline-fixture", "sourceThreadId": os.environ.get("CODEX_THREAD_ID")}})
    elif method == "turn/start":
        thread = params["threadId"]
        # All notifications deliberately arrive before the RPC response.
        send({"method": "turn/completed", "params": {"threadId": "another-thread", "turn": {"id": "other", "status": "failed"}}})
        send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "old-turn", "status": "completed"}}})
        send({"method": "item/completed", "params": {"threadId": "another-thread", "turnId": "fixture-turn", "item": {"id": "other-input", "type": "userMessage", "content": []}}})
        send({"method": "item/completed", "params": {"threadId": thread, "turnId": "old-turn", "item": {"id": "old-input", "type": "userMessage", "content": []}}})
        send({"method": "item/completed", "params": {"threadId": thread, "turnId": "old-turn", "item": {"id": "old", "type": "agentMessage", "phase": "final_answer", "text": "stale answer"}}})
        send({"method": "item/completed", "params": {"threadId": thread, "turnId": "fixture-turn", "item": {"id": "progress", "type": "agentMessage", "phase": "commentary", "text": "working"}}})
        if not os.environ.get("FAKE_OMIT_USER_MESSAGE"):
            user_message = {"method": "item/completed", "params": {"threadId": thread, "turnId": "fixture-turn", "item": {"id": "input", "type": "userMessage", "content": params["input"]}}}
            send(user_message)
            send(user_message)
        for tool_item in json.loads(os.environ.get("FAKE_TOOLS", "[]")):
            send({"method": "item/completed", "params": {"threadId": thread, "turnId": "fixture-turn", "item": tool_item}})
        send({"method": "item/completed", "params": {"threadId": thread, "turnId": "fixture-turn", "item": {"id": "answer", "type": "agentMessage", "phase": "final_answer", "text": "verified answer"}}})
        send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "fixture-turn", "status": "completed", "error": None}}})
        send({"id": ident, "result": {"turn": {"id": "fixture-turn", "status": "inProgress"}}})
    elif method == "turn/interrupt":
        send({"id": ident, "result": {}})
        send({"method": "turn/completed", "params": {"threadId": params["threadId"], "turn": {"id": params["turnId"], "status": "interrupted"}}})
    elif method == "fixture/error":
        send({"id": ident, "error": {"code": -32602, "message": "bad fixture input"}})
    elif method == "fixture/approval":
        send({"id": 9001, "method": "item/commandExecution/requestApproval", "params": {"threadId": "fixture"}})
    elif method == "fixture/invalid":
        print("invalid-json", flush=True)
    elif method == "fixture/eof":
        sys.exit(0)
    elif method == "fixture/hang":
        pass
    elif ident is not None:
        send({"id": ident, "result": {"echo": params}})
'''


class LocalPresetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-local-preset-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config_home = self.root / "config"
        self.preset = self.config_home / "codex-capture" / "followup.txt"
        self.data = self.root / "data"
        environment = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.config_home), "CODEX_CAPTURE_FOLLOWUP_FILE": ""})
        environment.start()
        self.addCleanup(environment.stop)
        data = mock.patch.object(capture, "DATA", self.data)
        data.start()
        self.addCleanup(data.stop)
        self.image = self.root / "input.png"
        self.image.write_bytes(b"original image bytes")

    def write_preset(self, data):
        self.preset.parent.mkdir(parents=True, exist_ok=True)
        self.preset.write_bytes(data)

    def args(self, followup=None):
        return argparse.Namespace(image=str(self.image), text="  Original task\n\n  Keep spacing.\n", followup=followup, model=None, no_open=True, read_only=False)

    def test_missing_or_empty_local_preset_disables_followup_without_creating_config(self):
        self.assertEqual(capture.resolve_followup(None), "")
        self.assertFalse(self.config_home.exists())
        self.write_preset(b"")
        self.assertEqual(capture.resolve_followup(None), "")

    def test_local_preset_preserves_bytes_as_utf8_text_and_submission_keeps_original_inputs(self):
        preset = "  Review these changes.\r\n\r\n    Summarize the result.\n"
        self.write_preset(preset.encode())
        self.assertEqual(capture.resolve_followup(None), preset)
        args = self.args()
        output = io.StringIO()
        with mock.patch.object(capture.subprocess, "Popen", return_value=mock.Mock(pid=123)), contextlib.redirect_stdout(output):
            capture.submit(args)
        result = json.loads(output.getvalue())
        request = capture.read_json(Path(result["statePath"]).with_name("request.json"))
        self.assertEqual(request["followup"], preset)
        self.assertEqual(request["text"], args.text)
        self.assertEqual(Path(request["image"]).read_bytes(), self.image.read_bytes())

    def test_explicit_followup_including_empty_never_reads_local_configuration(self):
        with mock.patch.object(capture, "followup_file", side_effect=AssertionError("must not read local configuration")):
            self.assertEqual(capture.resolve_followup(""), "")
            self.assertEqual(capture.resolve_followup("  custom\n"), "  custom\n")

    def test_home_default_and_explicit_file_override(self):
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": ""}), mock.patch.object(Path, "home", return_value=self.root):
            self.assertEqual(capture.followup_file(), (self.root / ".config/codex-capture/followup.txt", False))
        override = self.root / "private-preset.txt"
        override.write_text("override")
        with mock.patch.dict(os.environ, {"CODEX_CAPTURE_FOLLOWUP_FILE": str(override)}):
            self.assertEqual(capture.resolve_followup(None), "override")
            override.unlink()
            with self.assertRaisesRegex(ValueError, "找不到"):
                capture.resolve_followup(None)

    def test_invalid_private_configuration_errors_before_creating_job_and_hides_contents(self):
        invalid = (b"private-marker\xff", b"private-marker\x00", b"x" * (capture.FOLLOWUP_MAX_BYTES + 1))
        for value in invalid:
            with self.subTest(size=len(value)):
                self.write_preset(value)
                with mock.patch.object(capture.subprocess, "Popen") as worker:
                    with self.assertRaises(ValueError) as error:
                        capture.submit(self.args())
                self.assertNotIn("private-marker", str(error.exception))
                self.assertFalse(self.data.exists())
                worker.assert_not_called()
        self.write_preset(b"x" * capture.FOLLOWUP_MAX_BYTES)
        self.assertEqual(len(capture.resolve_followup(None)), capture.FOLLOWUP_MAX_BYTES)

    def test_unreadable_or_non_file_configuration_stops_without_capture_or_job(self):
        self.write_preset(b"private-marker")
        with mock.patch.object(Path, "open", side_effect=PermissionError("private-marker")):
            with self.assertRaisesRegex(ValueError, "无法读取") as error:
                capture.submit(self.args())
        self.assertNotIn("private-marker", str(error.exception))
        self.preset.unlink()
        self.preset.mkdir()
        with mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run") as screenshot:
            with self.assertRaisesRegex(ValueError, "普通"):
                capture.capture(self.args())
        screenshot.assert_not_called()
        self.assertFalse(self.data.exists())

    def test_cli_help_and_status_do_not_read_private_configuration(self):
        previous_umask = os.umask(0o077)
        self.addCleanup(os.umask, previous_umask)
        with mock.patch.object(capture, "followup_file", side_effect=AssertionError("unexpected config read")), contextlib.redirect_stdout(io.StringIO()):
            with mock.patch.object(sys, "argv", ["capture.py", "--help"]):
                with self.assertRaises(SystemExit) as exit_status:
                    capture.main()
                self.assertEqual(exit_status.exception.code, 0)
            with mock.patch.object(sys, "argv", ["capture.py", "status"]):
                capture.main()


class AppServerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-test-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        binary = self.directory / "fake-codex"
        binary.write_text("#!" + sys.executable + "\n" + textwrap.dedent(FAKE_SERVER))
        binary.chmod(0o700)
        self.binary_patch = mock.patch.object(capture, "codex_binary", return_value=str(binary))
        self.binary_patch.start()
        self.addCleanup(self.binary_patch.stop)

    def server(self):
        server = capture.AppServer(self.directory)
        self.addCleanup(server.close)
        return server

    def test_notifications_before_response_are_preserved_and_filtered(self):
        server = self.server()
        outcome = server.turn("target-thread", [{"type": "text", "text": "task"}], "initial", timeout=1)
        self.assertEqual(outcome["status"], "completed")
        self.assertEqual(outcome["finalText"], "verified answer")
        self.assertIsNone(server.active)
        persisted = json.loads((self.directory / "initial.json").read_text())
        self.assertEqual(persisted["id"], "fixture-turn")
        events = [json.loads(line) for line in (self.directory / "events.jsonl").read_text().splitlines()]
        self.assertTrue(all(row["threadId"] == "target-thread" for row in events))
        self.assertNotIn("stale answer", json.dumps(events))
        completions = [row for row in events if row["method"] == "turn/completed"]
        self.assertEqual(len(completions), 1, "stale completion with missing outer turnId must be filtered before logging")
        self.assertEqual(completions[0]["turnId"], "fixture-turn")

    def test_rpc_errors_are_not_mistaken_for_success(self):
        server = self.server()
        with self.assertRaisesRegex(RuntimeError, "bad fixture input"):
            server.request("fixture/error", {})

    def test_only_mutation_capable_completed_activity_is_recorded(self):
        examples = [
            ({"type": "commandExecution", "status": "completed", "exitCode": 0, "commandActions": [{"type": "read"}, {"type": "search"}]}, False),
            ({"type": "commandExecution", "status": "completed", "exitCode": 0, "commandActions": [{"type": "unknown"}]}, True),
            ({"type": "fileChange", "status": "failed", "changes": [{"path": "x.py", "diff": "patch"}]}, False),
            ({"type": "fileChange", "status": "completed", "changes": [{"path": "x.py", "diff": "patch"}]}, True),
        ]
        for item, expected in examples:
            with self.subTest(item=item), mock.patch.dict(os.environ, {"FAKE_TOOLS": json.dumps([item])}):
                server = self.server()
                result = server.turn("target-thread", [{"type": "text", "text": "task"}], "initial", timeout=1)
                self.assertEqual(result["mutationActivity"], expected)
                self.assertEqual(bool(result["fileChanges"]), item["type"] == "fileChange" and expected)

    def test_unattended_approval_requires_user_and_does_not_approve(self):
        server = self.server()
        with mock.patch.object(server, "send", wraps=server.send) as sent:
            with self.assertRaises(capture.NeedsInput):
                server.request("fixture/approval", {})
        reply = [call.args[0] for call in sent.call_args_list if call.args[0].get("id") == 9001]
        self.assertEqual(len(reply), 1)
        self.assertIn("error", reply[0])
        self.assertNotIn("result", reply[0])

    def test_invalid_json_and_early_eof_fail_promptly(self):
        for method in ("fixture/invalid", "fixture/eof"):
            with self.subTest(method=method):
                server = self.server()
                with self.assertRaises(RuntimeError):
                    server.request(method, {}, timeout=1)
                server.close()

    def test_request_timeout_is_bounded(self):
        server = self.server()
        with self.assertRaises(TimeoutError):
            server.request("fixture/hang", {}, timeout=0.03)

    def test_parent_chat_identity_is_not_inherited(self):
        with mock.patch.dict(os.environ, {"CODEX_THREAD_ID": "ancestor-chat"}):
            server = self.server()
        self.assertIsNone(server.info["sourceThreadId"])

    def test_handshake_failure_reaps_started_process(self):
        real_popen = subprocess.Popen
        processes = []

        def track(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            return process

        with mock.patch.dict(os.environ, {"FAKE_INIT_ERROR": "1"}), mock.patch.object(capture.subprocess, "Popen", side_effect=track):
            with self.assertRaisesRegex(RuntimeError, "handshake failed"):
                capture.AppServer(self.directory)
        try:
            self.assertEqual(len(processes), 1)
            self.assertIsNotNone(processes[0].poll(), "failed initialization left a live child process")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)

    def test_cancel_stops_and_confirms_active_turn_before_shutdown(self):
        server = self.server()
        server.active = {"threadId": "target-thread", "turnId": "active-turn"}
        (self.directory / "cancel").touch()
        with self.assertRaises(capture.Cancelled):
            server.request("fixture/hang", {}, timeout=1)
        shutdown = server.close()
        self.assertTrue(shutdown["interruptionRequested"])
        self.assertTrue(shutdown["interruptionConfirmed"])
        self.assertIsNone(server.active)


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-route-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.a, self.b = self.root / "a", self.root / "b"
        self.a.mkdir()
        self.b.mkdir()
        self.projects = [{"id": "project-a", "name": "A", "roots": [str(self.a)]}, {"id": "project-b", "name": "B", "roots": [str(self.b)]}]

    def test_valid_route_returns_exact_registered_project(self):
        project, root = capture.resolve_route({"projectId": "project-a", "rootPath": str(self.a), "confidence": 0.9}, self.projects)
        self.assertEqual(project, self.projects[0])
        self.assertEqual(root, str(self.a))

    def test_other_projects_root_cannot_be_used_for_selected_project(self):
        with self.assertRaises(capture.NeedsInput):
            capture.resolve_route({"projectId": "project-a", "rootPath": str(self.b), "confidence": 0.99}, self.projects)

    def test_null_unknown_and_uncertain_routes_require_input(self):
        for project_id, confidence in [(None, 1), ("unknown", 1), ("project-a", 0.69)]:
            with self.subTest(project=project_id, confidence=confidence), self.assertRaises(capture.NeedsInput):
                capture.resolve_route({"projectId": project_id, "rootPath": str(self.a), "confidence": confidence}, self.projects)

    def test_disappearing_directory_is_not_dispatched(self):
        self.a.rmdir()
        with self.assertRaises(capture.NeedsInput):
            capture.resolve_route({"projectId": "project-a", "rootPath": str(self.a), "confidence": 0.99}, self.projects)

    def test_only_existing_project_roots_are_eligible(self):
        self.a.rmdir()
        actual = capture.eligible_projects([{"id": "project-a", "name": "A", "roots": [{"path": str(self.a)}]}, {"id": "project-b", "name": "B", "roots": [{"path": str(self.b)}]}])
        self.assertEqual(actual, [self.projects[1]])


class FakeJobServer:
    def __init__(self, directory, project, *, initial_status="completed", confidence=0.99, fail_followup=False, initial_action=None, permission_response=None):
        self.directory = directory
        self.project = project
        self.initial_status = initial_status
        self.confidence = confidence
        self.fail_followup = fail_followup
        self.initial_action = initial_action
        self.permission_response = permission_response
        self.info = {"userAgent": "fake-job"}
        self.process = mock.Mock(pid=321)
        self.requests = []
        self.turns = []
        self.closed = False

    def projects(self):
        return [{"id": self.project["id"], "name": self.project["name"], "roots": [{"path": self.project["root"]}]}]

    def request(self, method, params):
        self.requests.append((method, params))
        if method == "thread/start":
            full_access = params.get("permissions") == ":danger-full-access"
            result = {"thread": {"id": "classifier" if params.get("ephemeral") else "main-thread", "projectId": params.get("projectId")}, "model": "default-main-model",
                      "activePermissionProfile": {"id": ":danger-full-access"} if full_access else None,
                      "sandbox": {"type": "dangerFullAccess" if full_access else "readOnly"},
                      "approvalPolicy": "never", "approvalsReviewer": "user"}
            if not params.get("ephemeral") and self.permission_response is not None:
                result.update(self.permission_response)
            return result
        return {}

    def turn(self, thread_id, inputs, stage, **kwargs):
        self.turns.append((thread_id, inputs, stage))
        if stage == "classification":
            route = {"projectId": self.project["id"], "rootPath": self.project["root"], "confidence": self.confidence, "reason": "fixture evidence", "title": "fixture task"}
            return {"id": "route-turn", "status": "completed", "finalText": json.dumps(route), "elapsedSeconds": 0.01}
        if stage == "initial" and self.initial_action:
            self.initial_action()
        if stage == "followup" and self.fail_followup:
            raise RuntimeError("transport lost after request may have been sent")
        return {"id": stage + "-turn", "status": self.initial_status if stage == "initial" else "completed", "finalText": "done", "elapsedSeconds": 0.01, "mutationActivity": True}

    def close(self):
        self.closed = True


class JobLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-job-test-")
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        patch = mock.patch.object(capture, "DATA", self.data)
        patch.start()
        self.addCleanup(patch.stop)
        self.project_dir = self.data / "project"
        self.project_dir.mkdir()
        self.project = {"id": "project-a", "name": "Project A", "root": str(self.project_dir)}
        self.job_id = "12345678-abcd"
        self.directory = capture.job_dir(self.job_id)
        self.directory.mkdir(parents=True)
        self.image = self.directory / "screenshot.png"
        self.image.write_bytes(b"fixture image bytes")
        capture.atomic_json(self.directory / "state.json", {"jobId": self.job_id, "phase": "queued", "followupAttempts": 0})
        capture.atomic_json(self.directory / "request.json", {"text": "fix this", "image": str(self.image), "followup": "review this", "model": None, "noOpen": True, "readOnly": False})
        self.snapshot_count = 0
        def snapshots(_root):
            self.snapshot_count += 1
            return {"complete": True, "root": str(self.project_dir), "files": {"app.py": "old" if self.snapshot_count % 2 else "new"}}
        self.snapshot_patch = mock.patch.object(capture, "workspace_snapshot", side_effect=snapshots)
        self.snapshot_patch.start()
        self.addCleanup(self.snapshot_patch.stop)

    def execute(self, **options):
        server = FakeJobServer(self.directory, self.project, **options)
        with mock.patch.object(capture, "AppServer", return_value=server):
            capture.run_job(self.job_id)
        return server, capture.read_json(self.directory / "state.json")

    def test_routes_native_image_and_follows_up_in_same_thread_once(self):
        server, state = self.execute()
        self.assertEqual(state["phase"], "completed")
        self.assertEqual(state["followupAttempts"], 1)
        starts = [params for method, params in server.requests if method == "thread/start"]
        self.assertEqual(starts[0]["model"], "gpt-6-luna")
        self.assertTrue(starts[0]["ephemeral"])
        self.assertEqual(starts[0]["sandbox"], "read-only")
        self.assertEqual(starts[0]["approvalPolicy"], "never")
        self.assertNotIn("permissions", starts[0])
        self.assertEqual(starts[1]["projectId"], "project-a")
        self.assertEqual(starts[1]["cwd"], str(self.project_dir))
        initial = next(turn for turn in server.turns if turn[2] == "initial")
        followup = next(turn for turn in server.turns if turn[2] == "followup")
        self.assertEqual(initial[0], followup[0])
        self.assertEqual(initial[1][0], {"type": "text", "text": "fix this"})
        self.assertNotIn("sandbox", starts[1])
        self.assertEqual(starts[1]["permissions"], ":danger-full-access")
        self.assertEqual(starts[1]["approvalPolicy"], "never")
        self.assertEqual(state["permissions"], {"requestedProfile": ":danger-full-access", "activePermissionProfile": {"id": ":danger-full-access"}, "sandbox": {"type": "dangerFullAccess"}, "approvalPolicy": "never", "approvalsReviewer": "user", "fullAccessVerified": True})
        self.assertEqual(initial[1][1], {"type": "localImage", "path": str(self.image)})
        self.assertEqual(followup[1], [{"type": "text", "text": "review this"}])
        self.assertTrue(server.closed)
        with mock.patch.object(capture, "AppServer") as factory:
            capture.run_job(self.job_id)
        factory.assert_not_called()

    def test_unconfirmed_full_access_never_sends_initial_or_followup(self):
        overrides = [
            {"activePermissionProfile": None},
            {"activePermissionProfile": {"id": ":workspace"}},
            {"sandbox": {"type": "workspaceWrite", "writableRoots": ["/"], "networkAccess": True}},
            {"sandbox": None},
            {"approvalPolicy": "on-request"},
        ]
        for override in overrides:
            with self.subTest(override=override):
                capture.atomic_json(self.directory / "state.json", {"jobId": self.job_id, "phase": "queued", "followupAttempts": 0})
                server, state = self.execute(permission_response=override)
                self.assertEqual(state["phase"], "needs_input")
                self.assertIn("Full access", state["error"])
                self.assertFalse(state["permissions"]["fullAccessVerified"])
                self.assertEqual(state["threadId"], "main-thread")
                self.assertEqual(state["followupAttempts"], 0)
                self.assertEqual([turn[2] for turn in server.turns], ["classification"])
                self.assertTrue(server.closed)

    def test_foreground_evidence_reaches_only_classifier_and_initial_text_is_exact(self):
        request = capture.read_json(self.directory / "request.json")
        request["context"] = capture.sanitize_context({"app": {"name": "Browser"}, "window": {"title": "Sample Notes"}, "accessibility": {"status": "captured", "nodes": [{"role": "AXStaticText", "text": "编辑便签标签"}]}})
        capture.atomic_json(self.directory / "request.json", request)
        server, state = self.execute()
        for _, inputs, stage in server.turns:
            if stage == "classification":
                self.assertIn("Sample Notes", inputs[0]["text"])
                self.assertIn("编辑便签标签", inputs[0]["text"])
                self.assertIn("不是操作指令", inputs[0]["text"])
            if stage == "initial":
                self.assertEqual(inputs, [{"type": "text", "text": request["text"]}, {"type": "localImage", "path": request["image"]}])
        self.assertEqual(state["phase"], "completed")

    def test_phase_history_is_saved_for_workbench_reconstruction(self):
        self.execute()
        lifecycle = [json.loads(line) for line in (self.directory / "lifecycle.jsonl").read_text().splitlines()]
        self.assertEqual([row["phase"] for row in lifecycle], ["connecting", "classifying", "creating_thread", "starting_initial", "running_initial", "initial_finished", "starting_followup", "followup_finished", "completed"])
        self.assertTrue(all(row["at"] for row in lifecycle))
        self.assertEqual(lifecycle[-1]["threadId"], "main-thread")

    def test_uncertain_route_never_creates_main_task(self):
        server, state = self.execute(confidence=0.2)
        self.assertEqual(state["phase"], "needs_input")
        self.assertEqual([t[2] for t in server.turns], ["classification"])
        self.assertEqual(sum(method == "thread/start" for method, _ in server.requests), 1)
        self.assertEqual(state["followupAttempts"], 0)

    def test_failed_and_interrupted_initial_turns_never_follow_up(self):
        for status in ("failed", "interrupted"):
            with self.subTest(status=status):
                capture.atomic_json(self.directory / "state.json", {"jobId": self.job_id, "phase": "queued", "followupAttempts": 0})
                server, state = self.execute(initial_status=status)
                self.assertEqual(state["phase"], "failed")
                self.assertEqual(state["followupAttempts"], 0)
                self.assertEqual([t[2] for t in server.turns], ["classification", "initial"])

    def test_ambiguous_followup_failure_is_not_replayed(self):
        server, state = self.execute(fail_followup=True)
        self.assertEqual(state["phase"], "failed")
        self.assertEqual(state["followupAttempts"], 1)
        with mock.patch.object(capture, "AppServer") as factory:
            capture.run_job(self.job_id)
        factory.assert_not_called()
        self.assertEqual(sum(t[2] == "followup" for t in server.turns), 1)

    def test_empty_preset_disables_followup(self):
        request = capture.read_json(self.directory / "request.json")
        request["followup"] = "  "
        capture.atomic_json(self.directory / "request.json", request)
        server, state = self.execute()
        self.assertEqual(state["phase"], "completed")
        self.assertEqual(state["followupAttempts"], 0)
        self.assertEqual([t[2] for t in server.turns], ["classification", "initial"])

    def test_desktop_opens_once_after_both_turns_and_runtime_close(self):
        request = capture.read_json(self.directory / "request.json")
        request["noOpen"] = False
        capture.atomic_json(self.directory / "request.json", request)
        server = FakeJobServer(self.directory, self.project)
        observed_stages = []

        def opened(*args, **kwargs):
            observed_stages.append(([turn[2] for turn in server.turns], server.closed, capture.read_json(self.directory / "state.json")["phase"]))
            return subprocess.CompletedProcess(args[0], 0)

        with mock.patch.object(capture, "AppServer", return_value=server), mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run", side_effect=opened) as launch:
            capture.run_job(self.job_id)
        self.assertEqual(observed_stages, [(["classification", "initial", "followup"], True, "completed")])
        launch.assert_called_once()
        self.assertEqual(launch.call_args.args[0], ["open", "-g", "codex://threads/main-thread"])
        self.assertEqual(launch.call_args.kwargs["timeout"], 15)
        state = capture.read_json(self.directory / "state.json")
        self.assertEqual(state["phase"], "completed")
        self.assertEqual(state["desktopOpenExitCode"], 0)

    def test_failed_and_interrupted_tasks_open_history_after_runtime_close(self):
        request = capture.read_json(self.directory / "request.json")
        request["noOpen"] = False
        capture.atomic_json(self.directory / "request.json", request)
        for status in ("failed", "interrupted"):
            with self.subTest(status=status):
                capture.atomic_json(self.directory / "state.json", {"jobId": self.job_id, "phase": "queued", "followupAttempts": 0})
                server = FakeJobServer(self.directory, self.project, initial_status=status)
                observations = []

                def opened(*args, **kwargs):
                    observations.append((server.closed, capture.read_json(self.directory / "state.json")["phase"]))
                    return subprocess.CompletedProcess(args[0], 0)

                with mock.patch.object(capture, "AppServer", return_value=server), mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run", side_effect=opened) as launch:
                    capture.run_job(self.job_id)
                self.assertEqual(observations, [(True, "failed")])
                self.assertEqual([turn[2] for turn in server.turns], ["classification", "initial"])
                self.assertEqual(launch.call_args.args[0], ["open", "-g", "codex://threads/main-thread"])
                self.assertEqual(capture.read_json(self.directory / "state.json")["phase"], "failed")

    def test_uncertain_route_does_not_open_classifier_as_a_task(self):
        request = capture.read_json(self.directory / "request.json")
        request["noOpen"] = False
        capture.atomic_json(self.directory / "request.json", request)
        with mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run") as launch:
            server, state = self.execute(confidence=0.2)
        launch.assert_not_called()
        self.assertTrue(server.closed)
        self.assertEqual(state["phase"], "needs_input")

    def test_desktop_open_failure_does_not_interrupt_task_or_followup(self):
        request = capture.read_json(self.directory / "request.json")
        request["noOpen"] = False
        capture.atomic_json(self.directory / "request.json", request)
        for error in (OSError("desktop unavailable"), subprocess.TimeoutExpired("open", 15)):
            with self.subTest(error=type(error).__name__):
                capture.atomic_json(self.directory / "state.json", {"jobId": self.job_id, "phase": "queued", "followupAttempts": 0})
                with mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run", side_effect=error):
                    server, state = self.execute()
                self.assertEqual(state["phase"], "completed")
                self.assertIn("desktopOpenError", state)
                self.assertEqual([turn[2] for turn in server.turns], ["classification", "initial", "followup"])

    def test_no_open_does_not_launch_desktop_after_completion(self):
        with mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run") as launch:
            _, state = self.execute()
        launch.assert_not_called()
        self.assertEqual(state["phase"], "completed")

    def test_submission_copies_input_and_detaches_worker(self):
        source = self.data / "input.png"
        source.write_bytes(b"original screenshot")
        args = argparse.Namespace(image=str(source), text="task", followup="next", model=None, no_open=True, read_only=True)
        output = io.StringIO()
        with mock.patch.object(capture.subprocess, "Popen", return_value=mock.Mock(pid=123)) as popen, contextlib.redirect_stdout(output):
            capture.submit(args)
        record = json.loads(output.getvalue())
        kwargs = popen.call_args.kwargs
        self.assertTrue(kwargs["start_new_session"])
        self.assertTrue(kwargs["close_fds"])
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        request_path = Path(record["statePath"]).with_name("request.json")
        image = Path(capture.read_json(request_path)["image"])
        source.unlink()
        self.assertEqual(image.read_bytes(), b"original screenshot")
        self.assertEqual(image.stat().st_mode & 0o777, 0o600)
        self.assertEqual(capture.read_json(record["statePath"])["phase"], "queued")

    def test_original_message_whitespace_and_readonly_policy_are_preserved(self):
        request = capture.read_json(self.directory / "request.json")
        request.update(text="  原始描述\n\n  保留缩进。\n", readOnly=True)
        capture.atomic_json(self.directory / "request.json", request)
        server, state = self.execute()
        initial = next(turn for turn in server.turns if turn[2] == "initial")
        self.assertEqual(initial[1][0]["text"], request["text"])
        starts = [params for method, params in server.requests if method == "thread/start"]
        self.assertEqual(starts[1]["sandbox"], "read-only")
        self.assertEqual(starts[1]["approvalPolicy"], "never")
        self.assertNotIn("permissions", starts[1])
        self.assertEqual(state["permissions"]["sandbox"], {"type": "readOnly"})
        self.assertNotIn("fullAccessVerified", state["permissions"])
        self.assertFalse(state["followupDecision"]["send"])
        self.assertIn("只读", state["followupDecision"]["reason"])

    def test_cancel_after_initial_completion_never_sends_preset(self):
        server, state = self.execute(initial_action=lambda: (self.directory / "cancel").touch())
        self.assertEqual(state["phase"], "cancelled")
        self.assertEqual(state["followupAttempts"], 0)
        self.assertEqual([turn[2] for turn in server.turns], ["classification", "initial"])

    def test_real_workspace_change_gate_in_job_pipeline(self):
        self.snapshot_patch.stop()
        subprocess.run(["git", "init", "-q", str(self.project_dir)], check=True)
        source = self.project_dir / "app.py"
        source.write_text("print('before')\n")
        for changed in (False, True):
            with self.subTest(changed=changed):
                capture.atomic_json(self.directory / "state.json", {"jobId": self.job_id, "phase": "queued", "followupAttempts": 0})
                action = (lambda: source.write_text("print('after')\n")) if changed else None
                server, state = self.execute(initial_action=action)
                self.assertEqual(state["followupDecision"]["send"], changed)
                self.assertEqual(state["followupAttempts"], int(changed))


class WorkspaceChangeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-git-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Capture Test")
        self.git("config", "user.email", "capture-test@example.invalid")
        self.source = self.root / "app.py"
        self.source.write_text("print('original')\n")
        self.git("add", "app.py")
        self.git("commit", "-qm", "Initial")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, check=True).stdout

    def snapshot(self):
        value = capture.workspace_snapshot(self.root)
        self.assertTrue(value["complete"], value)
        return value

    def decision(self, before, **kwargs):
        return capture.followup_decision({"status": "completed", "finalText": "I wrote code and fixed it", "mutationActivity": True}, TEST_FOLLOWUP, 0, before, self.snapshot(), **kwargs)

    def test_clean_or_preexisting_dirty_workspace_does_not_trigger(self):
        self.assertFalse(self.decision(self.snapshot())["send"])
        self.source.write_text("user's preexisting changes\n")
        (self.root / "new.py").write_text("user's preexisting untracked file\n")
        self.assertFalse(self.decision(self.snapshot())["send"])

    def test_tracked_and_untracked_changes_trigger(self):
        before = self.snapshot()
        self.source.write_text("print('fixed')\n")
        (self.root / "new.py").write_text("print('new')\n")
        decision = self.decision(before)
        self.assertTrue(decision["send"])
        self.assertEqual(decision["changedPaths"], ["app.py", "new.py"])

    def test_modifying_preexisting_dirty_content_triggers(self):
        self.source.write_text("preexisting\n")
        before = self.snapshot()
        self.source.write_text("new task edit\n")
        self.assertTrue(self.decision(before)["send"])

    def test_same_bytes_touch_or_reverted_edit_does_not_trigger(self):
        before = self.snapshot()
        original = self.source.read_bytes()
        self.source.write_text("temporary\n")
        self.source.write_bytes(original)
        self.assertFalse(self.decision(before)["send"])

    def test_committed_edit_is_detected_but_committing_old_dirt_is_not(self):
        self.source.write_text("old dirty\n")
        before = self.snapshot()
        self.git("commit", "-qam", "Commit old dirt")
        self.assertFalse(self.decision(before)["send"])
        before = self.snapshot()
        self.source.write_text("new code\n")
        self.git("commit", "-qam", "New code")
        self.assertTrue(self.decision(before)["send"])

    def test_checkout_without_task_edits_does_not_trigger(self):
        start = self.git("rev-parse", "HEAD").decode().strip()
        self.git("checkout", "-qb", "other")
        self.source.write_text("other branch code\n")
        self.git("commit", "-qam", "Other branch")
        self.git("checkout", "-q", start)
        before = self.snapshot()
        self.git("checkout", "-q", "other")
        self.assertFalse(self.decision(before)["send"])
        self.source.write_text("new task edit after checkout\n")
        self.assertTrue(self.decision(before)["send"])

    def test_deleted_file_is_detected(self):
        before = self.snapshot()
        self.source.unlink()
        self.assertEqual(self.decision(before)["changedPaths"], ["app.py"])

    def test_generated_logs_and_caches_do_not_trigger(self):
        before = self.snapshot()
        (self.root / "output.log").write_text("new log\n")
        (self.root / "__pycache__").mkdir()
        (self.root / "__pycache__" / "app.pyc").write_bytes(b"cache")
        (self.root / "dist").mkdir()
        (self.root / "dist" / "bundle.js").write_text("generated")
        self.assertFalse(self.decision(before)["send"])

    def test_tracked_source_under_build_directory_still_counts(self):
        (self.root / "build").mkdir()
        script = self.root / "build" / "build.py"
        script.write_text("original build source")
        self.git("add", "build/build.py")
        self.git("commit", "-qm", "Build script")
        before = self.snapshot()
        script.write_text("fixed build source")
        self.assertTrue(self.decision(before)["send"])

    def test_discussion_does_not_trigger_on_concurrent_file_changes(self):
        before = self.snapshot()
        self.source.write_text("another process changed this")
        decision = capture.followup_decision({"status": "completed", "mutationActivity": False}, TEST_FOLLOWUP, 0, before, self.snapshot())
        self.assertFalse(decision["send"])

    def test_successful_patch_proves_new_worktree_change_but_revert_does_not(self):
        before = self.snapshot()
        worktree = self.root / "other-worktree"
        self.git("worktree", "add", "-qb", "task", str(worktree))
        target = worktree / "app.py"
        original = target.read_bytes()
        target.write_text("task fix")
        initial = {"status": "completed", "mutationActivity": True, "fileChanges": [{"path": str(target), "hasDiff": True}]}
        decision = capture.followup_decision(initial, TEST_FOLLOWUP, 0, before, self.snapshot())
        self.assertTrue(decision["send"], decision)
        self.assertIn(str(target.resolve()), decision["changedPaths"])
        target.write_bytes(original)
        decision = capture.followup_decision(initial, TEST_FOLLOWUP, 0, before, self.snapshot())
        self.assertFalse(decision["send"], decision)

    def test_patch_fallback_works_when_full_manifest_exceeds_limit(self):
        with mock.patch.object(capture, "SNAPSHOT_MAX_FILES", 0):
            before = capture.workspace_snapshot(self.root)
        self.source.write_text("task patch")
        initial = {"status": "completed", "mutationActivity": True, "fileChanges": [{"path": str(self.source), "hasDiff": True}]}
        self.assertTrue(capture.followup_decision(initial, TEST_FOLLOWUP, 0, before, self.snapshot())["send"])

    def test_existing_worktree_checkout_with_reverted_patch_does_not_trigger(self):
        start = self.git("rev-parse", "HEAD").decode().strip()
        self.git("checkout", "-qb", "branch-b")
        self.source.write_text("branch B code")
        self.git("commit", "-qam", "Branch B")
        self.git("checkout", "-q", start)
        worktree = self.root / "other-worktree"
        self.git("worktree", "add", "--detach", str(worktree), start)
        before = self.snapshot()
        subprocess.run(["git", "-C", str(worktree), "checkout", "-q", "branch-b"], check=True)
        target = worktree / "app.py"
        original = target.read_bytes()
        target.write_text("temporary fix")
        target.write_bytes(original)
        initial = {"status": "completed", "mutationActivity": True, "fileChanges": [{"path": str(target), "hasDiff": True}]}
        self.assertFalse(capture.followup_decision(initial, TEST_FOLLOWUP, 0, before, self.snapshot())["send"])

    def test_unknown_or_oversized_workspace_is_conservatively_skipped(self):
        before = self.snapshot()
        self.source.write_text("new code")
        with mock.patch.object(capture, "SNAPSHOT_MAX_BYTES", 1):
            after = capture.workspace_snapshot(self.root)
        self.assertFalse(after["complete"])
        decision = capture.followup_decision({"status": "completed", "mutationActivity": True}, TEST_FOLLOWUP, 0, before, after)
        self.assertFalse(decision["send"])
        self.assertIn("无法可靠确认", decision["reason"])

    def test_failed_initial_and_already_sent_preset_never_follow_up(self):
        before = self.snapshot()
        self.source.write_text("new code")
        after = self.snapshot()
        for status, attempts in (("failed", 0), ("interrupted", 0), ("completed", 1)):
            self.assertFalse(capture.followup_decision({"status": status}, TEST_FOLLOWUP, attempts, before, after)["send"])


class ForegroundContextTests(unittest.TestCase):
    def test_secure_values_and_url_credentials_are_not_forwarded(self):
        value = capture.sanitize_context({
            "app": {"name": "Browser", "unknown": "do not forward"},
            "window": {"title": "Sample Notes", "url": "https://user:password@example.com/task?token=private#secret"},
            "accessibility": {"status": "captured", "nodes": [
                {"role": "AXTextField", "subrole": "AXSecureTextField", "text": "password123", "title": "secret title"},
                {"role": "AXTextArea", "text": "private draft", "value": "private value", "title": "Description"},
                {"role": "AXStaticText", "text": "编辑便签标签", "depth": 2, "parent": 1},
            ]},
        })
        encoded = json.dumps(value, ensure_ascii=False)
        for omitted in ("password", "token", "secret", "private draft", "private value", "do not forward"):
            self.assertNotIn(omitted, encoded)
        self.assertEqual(value["window"]["url"], "https://example.com/task")
        self.assertIn("编辑便签标签", encoded)
        self.assertEqual(value["accessibility"]["nodes"][-1]["sourceIndex"], 2)

    def test_context_size_is_bounded_and_truncation_is_explicit(self):
        value = capture.sanitize_context({"accessibility": {"nodes": [{"role": "AXStaticText", "text": "x" * 10000} for _ in range(1000)]}})
        self.assertTrue(value["accessibility"]["truncated"])
        self.assertLessEqual(len(value["accessibility"]["nodes"]), 200)
        self.assertLess(len(json.dumps(value)), 40000)

    def test_ipv6_url_remains_valid_after_sensitive_parts_are_removed(self):
        value = capture.sanitize_context({"window": {"url": "http://name:password@[::1]:3000/page?token=secret#anchor"}})
        self.assertEqual(value["window"]["url"], "http://[::1]:3000/page")

    def test_unavailable_accessibility_is_valid_evidence(self):
        value = capture.sanitize_context({"app": {"name": "Safari"}, "window": [], "accessibility": {"status": "permission_required", "nodes": None}})
        self.assertEqual(value["accessibility"]["status"], "permission_required")
        self.assertEqual(value["accessibility"]["nodes"], [])
        self.assertEqual(value["app"]["name"], "Safari")

    def test_malformed_or_oversized_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "context.json"
            path.write_text("[]")
            with self.assertRaises(ValueError):
                capture.load_context(path)
            path.write_bytes(b" " * (1024 * 1024 + 1))
            with self.assertRaisesRegex(ValueError, "1 MiB"):
                capture.load_context(path)

    def test_submit_persists_sanitized_context_before_source_disappears(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            image = directory / "input.png"
            image.write_bytes(b"screenshot")
            context = directory / "input.json"
            context.write_text(json.dumps({"window": {"title": "Project title"}, "arbitrary": "discard this"}))
            args = argparse.Namespace(image=str(image), text="task", followup="", model=None, no_open=True, read_only=True, context_file=str(context))
            output = io.StringIO()
            with mock.patch.object(capture, "DATA", directory), mock.patch.object(capture.subprocess, "Popen", return_value=mock.Mock(pid=123)), contextlib.redirect_stdout(output):
                capture.submit(args)
            record = json.loads(output.getvalue())
            context.unlink()
            request = capture.read_json(Path(record["statePath"]).with_name("request.json"))
            self.assertEqual(request["context"]["window"]["title"], "Project title")
            self.assertNotIn("arbitrary", request["context"])
            self.assertTrue(capture.read_json(record["statePath"])["hasForegroundContext"])


if __name__ == "__main__":
    unittest.main()
