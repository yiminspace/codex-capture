"""Screenshot-time routing checks; all projects, images and model responses are fixtures."""
import argparse
import collections
import threading
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "plugins/codex-capture/scripts/capture.py"
SPEC = importlib.util.spec_from_file_location("capture_preparation_under_test", SCRIPT)
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class FixtureServer:
    def __init__(self, directory, project, *, confidence=0.99, fail=False, on_close=None, on_classify=None):
        self.directory = Path(directory)
        self.project = project
        self.confidence = confidence
        self.fail = fail
        self.on_close = on_close
        self.on_classify = on_classify
        self.requests = []
        self.turns = []
        self.closed = False
        self.info = {"userAgent": "preparation-fixture"}
        self.process = mock.Mock(pid=12345)
        self.process.poll.return_value = None
        self.active = None
        self.pending = collections.deque()

    def projects(self):
        return [self.project] if self.project else []

    def request(self, method, params):
        self.requests.append((method, params))
        if method == "thread/start":
            ephemeral = params.get("ephemeral", False)
            return {"thread": {"id": "classifier" if ephemeral else "formal", "projectId": params.get("projectId")},
                    "model": "gpt-6-luna" if ephemeral else "fixture-model",
                    "activePermissionProfile": {"id": ":danger-full-access"},
                    "sandbox": {"type": "dangerFullAccess"}, "approvalPolicy": "never"}
        return {}

    def turn(self, thread_id, inputs, stage, **_kwargs):
        self.turns.append((thread_id, inputs, stage))
        if stage == "classification":
            if self.on_classify:
                self.on_classify()
            if self.fail:
                raise RuntimeError("fixture classification failure")
            route = {"projectId": self.project["id"], "rootPath": self.project["roots"][0]["path"],
                     "confidence": self.confidence, "reason": "synthetic screenshot fixture", "title": "fixture task"}
            result = {"status": "completed", "finalText": json.dumps(route), "elapsedSeconds": 0.1}
            capture.atomic_json(self.directory / "classification.json", result)
            capture.append_record(self.directory / "events.jsonl", {"stage": stage, "method": "turn/completed"})
            return result
        return {"status": "completed", "finalText": "fixture result", "elapsedSeconds": 0.1, "mutationActivity": False}

    def close(self):
        if self.on_close:
            self.on_close()
        self.closed = True
        return {"interruptionRequested": False}


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-prepare-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = self.root / "data"
        patch = mock.patch.object(capture, "DATA", self.data)
        patch.start()
        self.addCleanup(patch.stop)
        self.image = self.root / "synthetic.png"
        self.image.write_bytes(b"synthetic image bytes")
        self.project_root = self.root / "fixture-project"
        self.project_root.mkdir()
        self.project = {"id": "project-fixture", "name": "Fixture project", "roots": [{"path": str(self.project_root)}]}

    def prepare(self, context_file=None):
        args = argparse.Namespace(image=str(self.image), context_file=context_file)
        with mock.patch.object(capture.subprocess, "Popen", return_value=mock.Mock(pid=1234)) as spawn:
            result = capture.create_preparation(args)
        return result, spawn

    def directory(self, result):
        return Path(result["statePath"]).parent

    def classify(self, result, **options):
        directory = self.directory(result)
        server = FixtureServer(directory, self.project, **options)
        with mock.patch.object(capture, "AppServer", return_value=server):
            capture.run_preparation(result["preparationId"])
        return server

    def submit(self, result, text="  Change the fixture button.\n\n "):
        args = argparse.Namespace(image=None, context_file=None, preparation_id=result["preparationId"], text=text,
                                  followup="", model=None, no_open=True, read_only=False)
        output = io.StringIO()
        with mock.patch.object(capture.subprocess, "Popen", return_value=mock.Mock(pid=4321)) as spawn, contextlib.redirect_stdout(output):
            capture.submit(args)
        return json.loads(output.getvalue()), spawn

    def test_prepare_detaches_immediately_and_keeps_original_image_and_sanitized_context(self):
        context = self.root / "context.json"
        context.write_text(json.dumps({"app": {"name": "Fixture"}, "window": {"url": "https://fixture.invalid/path?secret=discard"},
                                       "accessibility": {"status": "captured", "nodes": [{"role": "AXTextField", "text": "do not retain"}]}}))
        result, spawn = self.prepare(str(context))
        self.assertEqual(set(result), {"preparationId", "statePath", "workerPid"})
        self.assertEqual(capture.read_json(Path(result["statePath"]))["phase"], "queued")
        self.assertEqual(spawn.call_args.args[0][-2:], ["_prepare", result["preparationId"]])
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        request = capture.read_json(self.directory(result) / "request.json")
        self.assertNotIn("text", request)
        self.assertEqual(Path(request["image"]).read_bytes(), self.image.read_bytes())
        self.assertEqual(request["context"]["window"]["url"], "https://fixture.invalid/path")
        self.assertNotIn("text", request["context"]["accessibility"]["nodes"][0])
        self.image.unlink()
        self.classify(result)
        self.assertEqual(capture.read_json(Path(result["statePath"]))["phase"], "ready")

    def test_prepare_classifies_read_only_without_creating_formal_thread(self):
        result, _ = self.prepare()
        server = self.classify(result)
        starts = [params for method, params in server.requests if method == "thread/start"]
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0]["model"], "gpt-6-luna")
        self.assertTrue(starts[0]["ephemeral"])
        self.assertEqual(starts[0]["sandbox"], "read-only")
        self.assertEqual([turn[2] for turn in server.turns], ["classification"])
        self.assertFalse((self.data / "jobs").exists())
        self.assertIn("用户正在输入需求", server.turns[0][1][0]["text"])
        state = capture.read_json(Path(result["statePath"]))
        self.assertEqual(state["project"]["name"], "Fixture project")
        self.assertEqual(state["cwd"], str(self.project_root))
        self.assertEqual(state["classifierModel"], "gpt-6-luna")

    def test_shared_service_reuses_transport_but_isolates_screenshot_threads(self):
        first, _ = self.prepare()
        second, _ = self.prepare()
        instances = []

        def factory(directory):
            server = FixtureServer(directory, self.project)
            instances.append(server)
            return server

        with mock.patch.object(capture, "AppServer", side_effect=factory):
            service = threading.Thread(target=capture.serve_classifier, kwargs={"idle_timeout": 0.3})
            service.start()
            try:
                deadline = time.monotonic() + 2
                while not capture.classifier_socket().exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                capture.request_preparation(first["preparationId"])
                capture.request_preparation(second["preparationId"])
            finally:
                service.join(3)
            self.assertFalse(service.is_alive())
        self.assertEqual(len(instances), 1)
        self.assertEqual(len(instances[0].turns), 2)
        self.assertEqual(len([request for method, request in instances[0].requests if method == "thread/start"]), 2)
        for result in (first, second):
            directory = self.directory(result)
            self.assertEqual(capture.read_json(directory / "state.json")["phase"], "ready")
            self.assertTrue((directory / "classification-debug.json").exists())
        self.assertNotEqual(instances[0].turns[0][1][1]["path"], instances[0].turns[1][1][1]["path"])
        self.assertTrue(instances[0].closed)

    def test_cancelled_queued_capture_does_not_acquire_warm_transport(self):
        result, _ = self.prepare()
        capture.cancel_preparation(result["preparationId"])
        pool = capture.ClassifierPool()
        with mock.patch.object(capture, "AppServer") as factory:
            with self.assertRaises(capture.Cancelled):
                pool.acquire(self.directory(result))
        factory.assert_not_called()
        self.assertTrue(pool.lock.acquire(blocking=False))
        pool.lock.release()

    def test_models_and_followup_are_configurable_with_explicit_cli_priority(self):
        capture.save_settings({"classifierModel": "fixture-classifier", "taskModel": "fixture-task", "followup": "  synthetic followup\n"})
        result, _ = self.prepare()
        # Changing defaults after this screenshot must not change its classification model.
        capture.save_settings({"classifierModel": "fixture-new", "taskModel": "fixture-task", "followup": "  synthetic followup\n"})
        server = self.classify(result)
        self.assertEqual(server.requests[0][1]["model"], "fixture-classifier")
        args = argparse.Namespace(image=str(self.image), text="fixture", followup=None, model=None, no_open=True, read_only=False)
        _, directory = capture.create_job(args, self.image, None, capture.resolve_followup(None))
        request = capture.read_json(directory / "request.json")
        self.assertEqual(request["model"], "fixture-task")
        self.assertEqual(request["followup"], "  synthetic followup\n")
        args.model = "fixture-explicit"
        _, directory = capture.create_job(args, self.image, None, capture.resolve_followup(""))
        self.assertEqual(capture.read_json(directory / "request.json")["model"], "fixture-explicit")
        self.assertEqual(capture.read_json(directory / "request.json")["followup"], "")

    def test_annotated_image_is_copied_separately_without_changing_original(self):
        marked = self.root / "marked.png"; marked.write_bytes(b"synthetic annotated pixels")
        args = argparse.Namespace(text="fixture", model=None, no_open=True, read_only=False, annotated_image=str(marked))
        _, directory = capture.create_job(args, self.image, None, "")
        request = capture.read_json(directory / "request.json")
        self.assertEqual(Path(request["image"]).read_bytes(), self.image.read_bytes())
        self.assertEqual(Path(request["annotatedImage"]).read_bytes(), marked.read_bytes())
        self.assertNotEqual(request["image"], request["annotatedImage"])
        marked.unlink()
        self.assertTrue(Path(request["annotatedImage"]).exists())

    def test_debug_preserves_actual_classifier_input_and_output(self):
        result, _ = self.prepare()
        server = self.classify(result)
        debug = capture.read_json(self.directory(result) / "classification-debug.json")
        self.assertEqual(debug["threadRequest"], server.requests[0][1])
        self.assertEqual(debug["turnRequest"]["input"], server.turns[0][1])
        self.assertEqual(json.loads(debug["turnResponse"]["finalText"])["projectId"], self.project["id"])
        self.assertIn("outputSchema", debug["turnRequest"])

    def test_debug_retains_input_when_classifier_fails(self):
        result, _ = self.prepare()
        self.classify(result, fail=True)
        debug = capture.read_json(self.directory(result) / "classification-debug.json")
        self.assertIn("turnRequest", debug)
        self.assertIn("fixture classification failure", debug["error"])

    def test_ready_is_published_after_classifier_close_and_worker_is_not_replayed(self):
        result, _ = self.prepare()
        phases = []
        server = self.classify(result, on_close=lambda: phases.append(capture.read_json(Path(result["statePath"]))["phase"]))
        self.assertEqual(phases, ["classifying"])
        self.assertTrue(server.closed)
        with mock.patch.object(capture, "AppServer") as factory:
            capture.run_preparation(result["preparationId"])
        factory.assert_not_called()

    def test_ready_submit_reuses_route_and_original_input_in_one_formal_thread(self):
        result, _ = self.prepare()
        self.classify(result)
        job, _ = self.submit(result)
        directory = Path(job["statePath"]).parent
        server = FixtureServer(directory, self.project)
        with mock.patch.object(capture, "AppServer", return_value=server):
            capture.run_job(job["jobId"])
        state = capture.read_json(Path(job["statePath"]))
        self.assertEqual(state["phase"], "completed")
        self.assertTrue(state["classificationReused"])
        self.assertEqual(state["preparationId"], result["preparationId"])
        self.assertEqual(len(server.turns), 1)
        self.assertEqual(server.turns[0][2], "initial")
        self.assertEqual(server.turns[0][1][0]["text"], "  Change the fixture button.\n\n ")
        self.assertEqual(Path(server.turns[0][1][1]["path"]).read_bytes(), b"synthetic image bytes")
        self.assertEqual([params for method, params in server.requests if method == "thread/start"][0]["projectId"], "project-fixture")
        self.assertEqual(capture.read_json(directory / "route.json")["projectId"], "project-fixture")
        self.assertEqual(capture.read_json(directory / "classification.json")["elapsedSeconds"], 0.1)
        self.assertIn('"stage": "classification"', (directory / "events.jsonl").read_text())

    def test_submit_while_classifying_waits_for_same_result_without_another_luna_turn(self):
        result, _ = self.prepare()
        job, _ = self.submit(result)
        directory = Path(job["statePath"]).parent
        classifier = FixtureServer(self.directory(result), self.project)
        formal = FixtureServer(directory, self.project)
        servers = iter([classifier, formal])
        def finish_preparation(_seconds):
            self.assertEqual(capture.read_json(Path(job["statePath"]))["phase"], "classifying")
            capture.run_preparation(result["preparationId"])
        with mock.patch.object(capture, "AppServer", side_effect=lambda _directory: next(servers)), mock.patch.object(capture.time, "sleep", side_effect=finish_preparation):
            capture.run_job(job["jobId"])
        self.assertEqual([turn[2] for turn in classifier.turns], ["classification"])
        self.assertEqual([turn[2] for turn in formal.turns], ["initial"])
        self.assertEqual(capture.read_json(Path(job["statePath"]))["phase"], "completed")

    def test_repeated_submit_returns_same_job_and_changed_text_is_rejected(self):
        result, _ = self.prepare()
        first, spawn = self.submit(result)
        second, retry_spawn = self.submit(result)
        self.assertEqual(first, second)
        spawn.assert_called_once()
        retry_spawn.assert_not_called()
        self.assertEqual(len(list((self.data / "jobs").iterdir())), 1)
        with self.assertRaisesRegex(ValueError, "已提交其他需求"):
            self.submit(result, text="A different requirement")

    def test_discard_before_submit_cancels_and_prevents_any_formal_job(self):
        result, _ = self.prepare()
        with contextlib.redirect_stdout(io.StringIO()):
            capture.discard_preparation(result["preparationId"])
        self.assertEqual(capture.read_json(Path(result["statePath"]))["phase"], "cancelled")
        with self.assertRaisesRegex(ValueError, "已取消"):
            self.submit(result)
        self.assertFalse((self.data / "jobs").exists())
        with mock.patch.object(capture, "AppServer") as factory:
            capture.run_preparation(result["preparationId"])
        factory.assert_not_called()

    def test_discard_after_submit_does_not_cancel_claimed_preparation(self):
        result, _ = self.prepare()
        job, _ = self.submit(result)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            capture.discard_preparation(result["preparationId"])
        self.assertEqual(json.loads(output.getvalue())["jobId"], job["jobId"])
        self.assertFalse((self.directory(result) / "cancel").exists())

    def test_job_cancel_while_waiting_cancels_only_its_preparation_without_formal_server(self):
        result, _ = self.prepare()
        other, _ = self.prepare()
        job, _ = self.submit(result)
        directory = Path(job["statePath"]).parent
        (directory / "cancel").touch()
        with mock.patch.object(capture, "AppServer") as factory:
            capture.run_job(job["jobId"])
        factory.assert_not_called()
        self.assertEqual(capture.read_json(Path(job["statePath"]))["phase"], "cancelled")
        self.assertTrue((self.directory(result) / "cancel").exists())
        self.assertFalse((self.directory(other) / "cancel").exists())

    def test_uncertain_route_explains_missing_accessibility_in_window_error(self):
        result, _ = self.prepare()
        directory = self.directory(result)
        request = capture.read_json(directory / "request.json")
        request["context"] = {"accessibility": {"status": "permission_required", "nodes": []}}
        capture.atomic_json(directory / "request.json", request)
        self.classify(result, confidence=0.2)
        state = capture.read_json(directory / "state.json")
        self.assertEqual(state["phase"], "needs_input")
        self.assertIn("AX 树与页面 URL 均未采集", state["error"])
        self.assertIn("synthetic screenshot fixture", state["error"])
        self.assertNotIn("route.json", state["error"])

    def test_failed_and_uncertain_preparations_never_start_formal_task(self):
        for options, expected in (({"fail": True}, "failed"), ({"confidence": 0.3}, "needs_input")):
            with self.subTest(options=options):
                result, _ = self.prepare()
                self.classify(result, **options)
                self.assertEqual(capture.read_json(Path(result["statePath"]))["phase"], expected)
                with self.assertRaises(capture.NeedsInput):
                    self.submit(result)
        self.assertFalse((self.data / "jobs").exists())

    def test_failure_after_submit_is_reported_without_reclassification_or_formal_task(self):
        result, _ = self.prepare()
        job, _ = self.submit(result)
        self.classify(result, fail=True)
        with mock.patch.object(capture, "AppServer") as factory:
            capture.run_job(job["jobId"])
        factory.assert_not_called()
        self.assertEqual(capture.read_json(Path(job["statePath"]))["phase"], "needs_input")

    def test_ready_route_is_revalidated_against_current_projects(self):
        result, _ = self.prepare()
        self.classify(result)
        job, _ = self.submit(result)
        server = FixtureServer(Path(job["statePath"]).parent, None)
        with mock.patch.object(capture, "AppServer", return_value=server):
            capture.run_job(job["jobId"])
        self.assertEqual(capture.read_json(Path(job["statePath"]))["phase"], "needs_input")
        self.assertFalse(server.requests)
        self.assertFalse(server.turns)

    def test_wait_detects_dead_worker_and_live_pid_without_worker_lock(self):
        result, _ = self.prepare()
        directory = self.directory(result)
        capture.atomic_json(directory / "state.json", {"phase": "classifying", "workerPid": os.getpid()})
        job_directory = self.root / "waiting-job"
        job_directory.mkdir()
        with mock.patch.object(capture.time, "monotonic", side_effect=[0, 0, 0, 6]):
            with self.assertRaisesRegex(capture.NeedsInput, "进程已退出"):
                capture.wait_for_preparation(result["preparationId"], job_directory)
        with mock.patch.object(capture.time, "monotonic", side_effect=[0, 0, 0, 6]), mock.patch.object(capture.os, "kill", side_effect=ProcessLookupError):
            with self.assertRaisesRegex(capture.NeedsInput, "进程已退出"):
                capture.wait_for_preparation(result["preparationId"], job_directory)

    def test_wait_reloads_terminal_state_when_worker_finishes_before_liveness_check(self):
        for phase in ("ready", "failed", "needs_input", "cancelled"):
            with self.subTest(phase=phase):
                result, _ = self.prepare()
                directory = self.directory(result)
                capture.atomic_json(directory / "state.json", {"phase": "classifying", "workerPid": 12345})
                job_directory = self.root / ("waiting-job-" + phase)
                job_directory.mkdir()
                def finish_and_exit(_pid, _signal):
                    capture.atomic_json(directory / "state.json", {"phase": phase, "workerPid": 12345, "error": "fixture terminal reason"})
                    raise ProcessLookupError()
                with mock.patch.object(capture.time, "monotonic", side_effect=[0, 0, 0, 6]), \
                     mock.patch.object(capture.os, "kill", side_effect=finish_and_exit):
                    if phase == "ready":
                        returned_directory, state = capture.wait_for_preparation(result["preparationId"], job_directory)
                        self.assertEqual(returned_directory, directory)
                        self.assertEqual(state["phase"], "ready")
                    else:
                        expected = capture.Cancelled if phase == "cancelled" else capture.NeedsInput
                        with self.assertRaisesRegex(expected, "fixture terminal reason"):
                            capture.wait_for_preparation(result["preparationId"], job_directory)
                self.assertFalse((directory / "cancel").exists())

    def test_wait_checks_cancellation_before_accepting_newly_published_ready_state(self):
        result, _ = self.prepare()
        directory = self.directory(result)
        capture.atomic_json(directory / "state.json", {"phase": "classifying", "workerPid": 12345})
        job_directory = self.root / "cancelled-waiting-job"
        job_directory.mkdir()
        def finish_and_cancel(_pid, _signal):
            capture.atomic_json(directory / "state.json", {"phase": "ready", "workerPid": 12345})
            (job_directory / "cancel").touch()
            raise ProcessLookupError()
        with mock.patch.object(capture.time, "monotonic", side_effect=[0, 0, 0, 6]), \
             mock.patch.object(capture.os, "kill", side_effect=finish_and_cancel):
            with self.assertRaises(capture.Cancelled):
                capture.wait_for_preparation(result["preparationId"], job_directory)
        self.assertTrue((directory / "cancel").exists())

    def test_wait_timeout_cancels_classification(self):
        result, _ = self.prepare()
        job_directory = self.root / "waiting-job"
        job_directory.mkdir()
        with mock.patch.object(capture.time, "monotonic", side_effect=[0, 0, 601]):
            with self.assertRaisesRegex(capture.NeedsInput, "超时"):
                capture.wait_for_preparation(result["preparationId"], job_directory)
        self.assertTrue((self.directory(result) / "cancel").exists())

    def test_invalid_missing_and_external_preparation_image_are_rejected(self):
        for identifier in ("../outside", "", "abcdef"):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                capture.preparation_dir(identifier)
        result, _ = self.prepare()
        capture.atomic_json(self.directory(result) / "request.json", {"image": str(self.image), "context": None})
        with self.assertRaisesRegex(ValueError, "图片位置无效"):
            self.submit(result)
        self.assertFalse((self.data / "jobs").exists())

    def test_interactive_cli_starts_preparation_before_prompt_and_discards_on_cancel_or_input_error(self):
        for outcome in ("cancel", "exception", "empty"):
            with self.subTest(outcome=outcome):
                args = argparse.Namespace(text=None, context_file=None, followup="", model=None, no_open=True, read_only=False)
                preparation_ids = []
                def command(arguments, **_kwargs):
                    if arguments[0] == "screencapture":
                        Path(arguments[-1]).write_bytes(b"synthetic CLI screenshot")
                        return mock.Mock(returncode=0)
                    preparations = list((self.data / "preparations").glob("*/state.json"))
                    current = [path for path in preparations if capture.read_json(path)["phase"] == "queued"]
                    self.assertEqual(len(current), 1, "classification must start before input prompt")
                    preparation_ids.append(current[0].parent.name)
                    if outcome == "exception":
                        raise RuntimeError("fixture input failure")
                    return mock.Mock(returncode=1 if outcome == "cancel" else 0, stdout="\n")
                with mock.patch.object(capture.sys, "platform", "darwin"), mock.patch.object(capture.subprocess, "run", side_effect=command), mock.patch.object(capture.subprocess, "Popen", return_value=mock.Mock(pid=1234)):
                    if outcome == "cancel":
                        capture.capture(args)
                    else:
                        with self.assertRaises((ValueError, RuntimeError)):
                            capture.capture(args)
                state = capture.read_json(capture.preparation_dir(preparation_ids[0]) / "state.json")
                self.assertEqual(state["phase"], "cancelled")
                self.assertFalse((self.data / "jobs").exists())

    def test_cli_prepares_while_typing_and_executes_using_one_real_subprocess_classification(self):
        """Exercise the real detached worker/stdio contract against a synthetic server."""
        executable = self.root / "fixture-codex"
        request_log = self.root / "requests.jsonl"
        gate = self.root / "classification-may-finish"
        executable.write_text("#!" + sys.executable + "\n" + r'''
import json, os, pathlib, sys, time
def send(message):
    print(json.dumps(message), flush=True)
for line in sys.stdin:
    message = json.loads(line)
    method, ident = message.get("method"), message.get("id")
    params = message.get("params", {})
    with open(os.environ["FIXTURE_REQUEST_LOG"], "a") as log:
        log.write(json.dumps(message) + "\n")
    if method == "initialize":
        send({"id": ident, "result": {"userAgent": "subprocess-fixture"}})
    elif method == "project/list":
        send({"id": ident, "result": {"data": [{"id": "fixture-project", "name": "Fixture project", "roots": [{"path": os.environ["FIXTURE_PROJECT_ROOT"]}]}]}})
    elif method == "thread/start":
        classifier = bool(params.get("ephemeral"))
        send({"id": ident, "result": {"thread": {"id": "classifier" if classifier else "formal", "projectId": params.get("projectId")},
            "model": "gpt-6-luna" if classifier else "fixture-main", "activePermissionProfile": {"id": ":danger-full-access"},
            "sandbox": {"type": "dangerFullAccess"}, "approvalPolicy": "never"}})
    elif method == "turn/start":
        thread = params["threadId"]
        send({"id": ident, "result": {"turn": {"id": thread + "-turn"}}})
        if thread == "classifier":
            deadline = time.monotonic() + 15
            while not pathlib.Path(os.environ["FIXTURE_GATE"]).exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            text = json.dumps({"projectId": "fixture-project", "rootPath": os.environ["FIXTURE_PROJECT_ROOT"], "confidence": 0.99, "reason": "synthetic fixture", "title": "fixture"})
        else:
            text = "Fixture execution completed."
        send({"method": "item/completed", "params": {"threadId": thread, "turnId": thread + "-turn", "item": {"type": "agentMessage", "id": thread + "-answer", "phase": "final_answer", "text": text}}})
        send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": thread + "-turn", "status": "completed"}}})
    elif ident is not None:
        send({"id": ident, "result": {}})
''')
        executable.chmod(0o700)
        environment = dict(os.environ, CODEX_CAPTURE_DATA=str(self.data), CODEX_CAPTURE_CODEX_BIN=str(executable),
                           XDG_CONFIG_HOME=str(self.root / "empty-config"), CODEX_CAPTURE_FOLLOWUP_FILE="",
                           FIXTURE_REQUEST_LOG=str(request_log), FIXTURE_PROJECT_ROOT=str(self.project_root), FIXTURE_GATE=str(gate))

        def cli(*arguments):
            result = subprocess.run([sys.executable, str(SCRIPT), *arguments], env=environment,
                                    capture_output=True, text=True, timeout=10, check=True)
            return json.loads(result.stdout)

        def requests():
            return [json.loads(line) for line in request_log.read_text().splitlines()] if request_log.exists() else []

        def await_condition(condition):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                result = condition()
                if result:
                    return result
                time.sleep(0.03)
            self.fail("Synthetic subprocess did not reach expected state")

        context = self.root / "context.json"
        context.write_text(json.dumps({
            "window": {"title": "Fixture project", "url": "https://fixture.invalid/notes"},
            "accessibility": {"status": "captured", "nodes": [{"role": "AXHeading", "title": "Notes"}]},
        }))
        prepared = cli("prepare", "--image", str(self.image), "--context-file", str(context))
        try:
            await_condition(lambda: any(row.get("method") == "turn/start" for row in requests()))
            self.assertEqual(capture.read_json(Path(prepared["statePath"]))["phase"], "classifying")
            original = "  Change this synthetic button.\n\nPreserve spaces.  "
            job = cli("submit", "--preparation-id", prepared["preparationId"], "--text=" + original, "--followup=", "--no-open")
            await_condition(lambda: capture.read_json(Path(job["statePath"]))["phase"] == "classifying")
            self.assertFalse(any(row.get("method") == "thread/start" and not row["params"].get("ephemeral") for row in requests()))
        finally:
            gate.touch()
        def finished_state():
            value = capture.read_json(Path(job["statePath"]))
            return value if value.get("shutdown") is not None else None
        state = await_condition(finished_state)
        self.assertEqual(state["phase"], "completed")
        self.assertTrue(state["classificationReused"])
        turns = [row for row in requests() if row.get("method") == "turn/start"]
        self.assertEqual([row["params"]["threadId"] for row in turns], ["classifier", "formal"])
        classification_input = turns[0]["params"]["input"]
        self.assertEqual([item["type"] for item in classification_input], ["text"])
        self.assertIn("https://fixture.invalid/notes", classification_input[0]["text"])
        self.assertNotIn(original, classification_input[0]["text"])
        self.assertEqual(turns[1]["params"]["input"][0]["text"], original)
        image = Path(turns[1]["params"]["input"][1]["path"])
        self.assertEqual(image.read_bytes(), self.image.read_bytes())
        # The next screenshot must reuse the classifier's stdio transport while
        # still issuing a fresh ephemeral thread/start and a new turn.
        before = requests()
        initialize_count = sum(row.get("method") == "initialize" for row in before)
        second = cli("prepare", "--image", str(self.image))
        await_condition(lambda: capture.read_json(Path(second["statePath"]))["phase"] == "ready")
        after = requests()
        self.assertEqual(sum(row.get("method") == "initialize" for row in after), initialize_count)
        self.assertEqual(sum(row.get("method") == "thread/start" and row["params"].get("ephemeral", False) for row in after), 2)
        self.assertEqual(sum(row.get("method") == "turn/start" and row["params"]["threadId"] == "classifier" for row in after), 2)


if __name__ == "__main__":
    unittest.main()
