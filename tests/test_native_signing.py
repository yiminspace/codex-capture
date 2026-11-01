"""Signing policy tests; fixtures never create keychains, certificates or trust."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/native_signing.py"
SPEC = importlib.util.spec_from_file_location("capture_native_signing_under_test", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class NativeSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="capture-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "signing"
        self.certificate = b"synthetic public certificate fixture"
        self.identity = hashlib.sha1(self.certificate).hexdigest().upper()
        environment = mock.patch.dict(os.environ, {"CODEX_CAPTURE_SIGNING_IDENTITY": ""})
        environment.start()
        self.addCleanup(environment.stop)
        platform = mock.patch.object(signing.sys, "platform", "darwin")
        platform.start()
        self.addCleanup(platform.stop)

    def ensure_external(self, **options):
        with mock.patch.object(signing, "_available") as available, mock.patch.object(signing, "_public_certificate", return_value=self.certificate):
            plan = signing.ensure(self.state, self.identity, **options)
        return plan, available

    def test_external_identity_is_exact_and_persisted_without_secret_material(self):
        plan, available = self.ensure_external()
        self.assertTrue(plan["created"])
        self.assertEqual(plan["identityType"], "existing")
        self.assertEqual(plan["identitySHA1"], self.identity)
        self.assertEqual(plan["certificateSHA256"], hashlib.sha256(self.certificate).hexdigest())
        self.assertEqual(plan["designatedRequirement"], signing.requirement(self.identity))
        self.assertIsNone(plan["keychainPath"])
        self.assertIsNone(plan["trustScope"])
        self.assertEqual(set(path.name for path in self.state.iterdir()), {"owner.json", "identity.json", "certificate.der"})
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in self.state.iterdir()))
        available.assert_any_call(self.identity)

    def test_repeat_setup_preserves_identity_and_never_creates_or_repairs_credentials(self):
        first, _ = self.ensure_external()
        original = (self.state / "identity.json").read_bytes()
        with mock.patch.object(signing, "_available"), mock.patch.object(signing, "_create_local_identity") as create:
            again = signing.ensure(self.state)
        self.assertFalse(again["created"])
        self.assertEqual(again["identitySHA1"], first["identitySHA1"])
        self.assertEqual((self.state / "identity.json").read_bytes(), original)
        create.assert_not_called()

    def test_first_managed_identity_initializes_without_trust_permission(self):
        def create(stage):
            for name, value in (("certificate.der", self.certificate), ("signing.keychain-db", b"fixture keychain"), ("keychain-password", b"x" * 48)):
                (stage / name).write_bytes(value)
                (stage / name).chmod(0o600)
            return self.identity, self.certificate
        with mock.patch.object(signing, "_create_local_identity", side_effect=create) as create_identity, mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain") as register, mock.patch.object(signing, "_check_signing_key") as probe:
            plan = signing.ensure(self.state)
        self.assertTrue(plan["created"])
        self.assertFalse(plan["trustStoreModified"])
        self.assertIsNone(plan["trustScope"])
        create_identity.assert_called_once()
        old_keychain = create_identity.call_args.args[0] / "signing.keychain-db"
        register.assert_called_once_with(self.state / "signing.keychain-db", previous_keychain=old_keychain)
        probe.assert_called_once_with(self.state, self.identity)

    def test_missing_whole_state_directory_never_rotates_an_existing_signed_app(self):
        previous = {"identifier": signing.APP_ID, "identitySHA1": self.identity, "adhoc": False}
        for requested in (None, "A" * 40):
            with self.subTest(requested=requested), mock.patch.object(signing, "inspect", return_value=previous), mock.patch.object(signing, "_create_local_identity") as create:
                with self.assertRaisesRegex(signing.SigningError, "不会创建新证书"):
                    signing.ensure(self.state, requested, previous_app="existing.app")
                create.assert_not_called()
                self.assertFalse(self.state.exists())
        with mock.patch.object(signing, "inspect", return_value=previous), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_public_certificate", return_value=self.certificate):
            recovered = signing.ensure(self.state, self.identity, previous_app="existing.app")
        self.assertEqual(recovered["identitySHA1"], self.identity)

    def test_failed_partial_bootstrap_rolls_back_only_before_pinning_identity(self):
        commands = []
        def fail_creation(stage, **_options):
            (stage / "certificate.der").write_bytes(self.certificate)
            (stage / "certificate.der").chmod(0o600)
            (stage / "signing.keychain-db").write_bytes(b"fixture keychain")
            (stage / "signing.keychain-db").chmod(0o600)
            raise signing.SigningError("fixture transient failure")
        with mock.patch.object(signing, "_create_local_identity", side_effect=fail_creation), mock.patch.object(signing, "_keychain_search_list", return_value=[]), mock.patch.object(signing, "_security", side_effect=lambda args: commands.append(args)):
            with self.assertRaisesRegex(signing.SigningError, "transient failure"):
                signing.ensure(self.state)
        self.assertFalse(self.state.exists())
        self.assertFalse(list(self.root.glob(".signing-bootstrap-*")))
        self.assertEqual([args[0] for args in commands], ["delete-keychain"])
        self.assertTrue(all(Path(args[-1]).parent.name.startswith(".signing-bootstrap-") for args in commands))

    def pending_stage(self):
        stage = self.root / ".signing-bootstrap-fixture"
        stage.mkdir(mode=0o700)
        signing._write_json(stage / "owner.json", {"owner": signing.OWNER, "uid": os.getuid()})
        signing._write_json(stage / "trust-pending.json", {"identitySHA1": self.identity})
        for name, value in (("certificate.der", self.certificate), ("signing.keychain-db", b"fixture keychain"), ("keychain-password", b"x" * 48)):
            (stage / name).write_bytes(value)
            (stage / name).chmod(0o600)
        return stage

    def test_auth_failure_retains_and_resumes_same_pinned_identity_without_regeneration(self):
        stage = self.pending_stage()
        with mock.patch.object(signing, "_complete_local_bootstrap", side_effect=signing.SigningError("fixture authorization timeout")), mock.patch.object(signing, "_create_local_identity") as create, mock.patch.object(signing, "_cleanup_bootstrap") as cleanup:
            with self.assertRaisesRegex(signing.SigningError, "保留同一证书"):
                signing.ensure(self.state)
        self.assertTrue(stage.is_dir())
        self.assertFalse(self.state.exists())
        create.assert_not_called()
        cleanup.assert_not_called()
        with mock.patch.object(signing, "_complete_local_bootstrap", return_value=(self.identity, self.certificate)) as complete, mock.patch.object(signing, "_create_local_identity") as create, mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain"), mock.patch.object(signing, "_check_signing_key"):
            plan = signing.ensure(self.state)
        complete.assert_called_once_with(stage)
        create.assert_not_called()
        self.assertFalse(stage.exists())
        self.assertTrue(self.state.is_dir())
        self.assertEqual(plan["identitySHA1"], self.identity)

    def test_new_setup_marker_also_resumes_same_certificate(self):
        stage = self.pending_stage()
        (stage / "trust-pending.json").rename(stage / "setup-pending.json")
        with mock.patch.object(signing, "_complete_local_bootstrap", return_value=(self.identity, self.certificate)) as complete, mock.patch.object(signing, "_create_local_identity") as create, mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain"), mock.patch.object(signing, "_check_signing_key"):
            plan = signing.ensure(self.state)
        complete.assert_called_once_with(stage)
        create.assert_not_called()
        self.assertEqual(plan["identitySHA1"], self.identity)

    def test_final_path_probe_failure_keeps_published_identity_and_retry_repairs_registration(self):
        stage = self.pending_stage()
        with mock.patch.object(signing, "_complete_local_bootstrap", return_value=(self.identity, self.certificate)), mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain") as register, mock.patch.object(signing, "_check_signing_key", side_effect=signing.SigningError("fixture final probe failed")) as probe:
            with self.assertRaisesRegex(signing.SigningError, "final probe failed"):
                signing.ensure(self.state)
        self.assertTrue(self.state.is_dir())
        self.assertFalse(stage.exists())
        original_metadata = (self.state / "identity.json").read_bytes()
        register.assert_called_once_with(self.state / "signing.keychain-db", previous_keychain=stage / "signing.keychain-db")
        probe.assert_called_once_with(self.state, self.identity)
        with mock.patch.object(signing, "_create_local_identity") as create, mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain") as register, mock.patch.object(signing, "_check_signing_key") as probe:
            recovered = signing.ensure(self.state)
        self.assertFalse(recovered["created"])
        self.assertEqual(recovered["identitySHA1"], self.identity)
        self.assertEqual(original_metadata, (self.state / "identity.json").read_bytes())
        create.assert_not_called()
        register.assert_called_once_with(self.state / "signing.keychain-db", previous_keychain=stage / "signing.keychain-db")
        probe.assert_called_once_with(self.state, self.identity)

    def test_invalid_saved_bootstrap_path_cannot_remove_an_unrelated_keychain(self):
        stage = self.pending_stage()
        with mock.patch.object(signing, "_complete_local_bootstrap", return_value=(self.identity, self.certificate)), mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain"), mock.patch.object(signing, "_check_signing_key"):
            signing.ensure(self.state)
        path = self.state / "identity.json"
        metadata = signing._read_json(path)
        metadata["bootstrapDirectory"] = "../other-app"
        signing._write_json(path, metadata)
        with mock.patch.object(signing, "_unlock", return_value=self.state / "signing.keychain-db"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain") as register:
            with self.assertRaisesRegex(signing.SigningError, "准备目录记录无效"):
                signing.ensure(self.state)
        register.assert_not_called()

    def test_resume_registers_keychain_and_probes_without_trust_changes(self):
        stage = self.pending_stage()
        with mock.patch.object(signing, "_unlock", return_value=stage / "signing.keychain-db"), mock.patch.object(signing, "_available") as available, mock.patch.object(signing, "_run"), mock.patch.object(signing, "_check_signing_key") as probe, mock.patch.object(signing, "_register_keychain") as register:
            identity, _ = signing._complete_local_bootstrap(stage)
        self.assertEqual(identity, self.identity)
        register.assert_called_once_with(stage / "signing.keychain-db")
        available.assert_called_once_with(self.identity, stage / "signing.keychain-db", require_valid=False)
        probe.assert_called_once_with(stage, self.identity)

    def test_probe_failure_preserves_same_identity_without_trust_retry(self):
        stage = self.pending_stage()
        with mock.patch.object(signing, "_unlock", return_value=stage / "signing.keychain-db"), mock.patch.object(signing, "_available"), mock.patch.object(signing, "_run"), mock.patch.object(signing, "_register_keychain"), mock.patch.object(signing, "_check_signing_key", side_effect=signing.SigningError("fixture cannot sign")) as probe, mock.patch.object(signing, "_security") as security:
            with self.assertRaisesRegex(signing.SigningError, "cannot sign"):
                signing._complete_local_bootstrap(stage)
        probe.assert_called_once()
        security.assert_not_called()
        self.assertTrue((stage / "trust-pending.json").exists())

    def test_keychain_registration_preserves_existing_paths_and_default(self):
        existing = ["/fixture/login.keychain-db", "/fixture/a keychain.keychain-db"]
        commands = []
        def security(arguments):
            commands.append(arguments)
            return "\n".join(json.dumps(path) for path in existing), ""
        with mock.patch.object(signing, "_security", side_effect=security):
            signing._register_keychain(self.state / "signing.keychain-db")
        self.assertEqual(commands, [["list-keychains", "-d", "user"], ["list-keychains", "-d", "user", "-s", *existing, str(self.state / "signing.keychain-db")]])

    def test_keychain_registration_replaces_only_own_stage_entry(self):
        old = self.root / ".signing-bootstrap-fixture/signing.keychain-db"
        new = self.state / "signing.keychain-db"
        existing = ["/fixture/login.keychain-db", str(old), "/fixture/added-by-another-app.keychain-db"]
        with mock.patch.object(signing, "_keychain_search_list", return_value=existing), mock.patch.object(signing, "_security") as security:
            signing._register_keychain(new, previous_keychain=old)
        security.assert_called_once_with(["list-keychains", "-d", "user", "-s", existing[0], str(new), existing[2]])
        with mock.patch.object(signing, "_keychain_search_list", return_value=[str(new), *existing]), mock.patch.object(signing, "_security") as security:
            signing._register_keychain(new, previous_keychain=old)
        security.assert_called_once_with(["list-keychains", "-d", "user", "-s", str(new), existing[0], existing[2]])

    def test_repeated_keychain_registration_is_read_only(self):
        keychain = self.state / "signing.keychain-db"
        with mock.patch.object(signing, "_keychain_search_list", return_value=["/fixture/login.keychain-db", str(keychain)]), mock.patch.object(signing, "_security") as security:
            signing._register_keychain(keychain)
        security.assert_not_called()

    def test_cleanup_reads_fresh_search_list_and_removes_only_owned_keychain(self):
        keychain = self.state / "signing.keychain-db"
        existing = ["/fixture/login.keychain-db", str(keychain), "/fixture/new-other-app.keychain-db"]
        with mock.patch.object(signing, "_keychain_search_list", return_value=existing), mock.patch.object(signing, "_security") as security:
            signing._unregister_keychain(keychain)
        security.assert_called_once_with(["list-keychains", "-d", "user", "-s", existing[0], existing[2]])

    def test_probe_never_follows_a_leftover_fixed_name_symlink(self):
        stage = self.pending_stage()
        outside = self.root / "keep-unchanged"
        outside.write_bytes(b"fixture outside file")
        (stage / "signing-probe").symlink_to(outside)
        with mock.patch.object(signing, "_run") as run:
            signing._check_signing_key(stage, self.identity)
        self.assertEqual(outside.read_bytes(), b"fixture outside file")
        paths = [Path(call.args[0][-1]) for call in run.call_args_list]
        self.assertTrue(all(path.name.startswith("signing-probe-") for path in paths))
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertTrue((stage / "signing-probe").is_symlink())

    def test_symlink_in_private_ancestor_is_rejected(self):
        real = self.root / "private-base"
        real.mkdir()
        link = self.root / "base-link"
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(signing.SigningError, "符号链接"):
            signing.ensure(link / "signing", self.identity)
        self.assertFalse((real / "signing").exists())

    def test_unknown_or_partially_created_state_is_never_overwritten(self):
        self.state.mkdir(mode=0o700)
        sentinel = self.state / "keep-me"
        sentinel.write_text("fixture")
        with mock.patch.object(signing, "_create_local_identity") as create, self.assertRaises(signing.SigningError):
            signing.ensure(self.state)
        self.assertEqual(sentinel.read_text(), "fixture")
        create.assert_not_called()
        signing._write_json(self.state / "owner.json", {"owner": signing.OWNER, "uid": os.getuid()})
        with self.assertRaises(signing.SigningError):
            signing.ensure(self.state)
        self.assertFalse((self.state / "identity.json").exists())

    def test_missing_corrupt_or_replaced_certificate_fails_without_rotation(self):
        self.ensure_external()
        certificate = self.state / "certificate.der"
        for bad in (None, b"other fixture certificate"):
            with self.subTest(bad=bad):
                if bad is None:
                    certificate.unlink()
                else:
                    certificate.write_bytes(bad)
                    certificate.chmod(0o600)
                with mock.patch.object(signing, "_create_local_identity") as create, self.assertRaises(signing.SigningError):
                    signing.ensure(self.state)
                create.assert_not_called()

    def test_explicit_different_identity_never_replaces_pinned_state(self):
        self.ensure_external()
        original = (self.state / "identity.json").read_bytes()
        with self.assertRaisesRegex(signing.SigningError, "不会自动切换"):
            signing.ensure(self.state, "A" * 40)
        self.assertEqual((self.state / "identity.json").read_bytes(), original)

    def test_identity_names_ad_hoc_and_partial_fingerprints_are_rejected(self):
        for identity in ("-", "Codex Capture", "A" * 39, 123, "A" * 40 + " --sign -"):
            with self.subTest(identity=identity), self.assertRaises(signing.SigningError):
                signing.ensure(self.state, identity)
        self.assertFalse(self.state.exists())

    def test_symlink_world_readable_and_foreign_owned_files_are_rejected(self):
        self.state.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(signing.SigningError):
            signing.ensure(self.state, self.identity)
        self.state.unlink()
        self.ensure_external()
        path = self.state / "identity.json"
        path.chmod(0o644)
        with self.assertRaisesRegex(signing.SigningError, "权限为 600"):
            signing.ensure(self.state)
        path.chmod(0o600)
        with mock.patch.object(signing.os, "getuid", return_value=os.getuid() + 1), self.assertRaises(signing.SigningError):
            signing.ensure(self.state)

    def test_unavailable_pinned_identity_fails_without_recreating_it(self):
        self.ensure_external()
        with mock.patch.object(signing, "_available", side_effect=signing.SigningError("fixture unavailable")), mock.patch.object(signing, "_create_local_identity") as create:
            with self.assertRaisesRegex(signing.SigningError, "unavailable"):
                signing.ensure(self.state)
        create.assert_not_called()

    def test_security_passwords_only_go_through_stdin_and_never_error_text(self):
        secret = "synthetic-password-do-not-print"
        response = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(signing.subprocess, "run", return_value=response) as run:
            signing._security(["unlock-keychain", "-p", secret, "/fixture/keychain with spaces"], secret=True)
        arguments = run.call_args.args[0]
        self.assertEqual(arguments, [signing.SECURITY, "-i"])
        self.assertNotIn(secret, " ".join(arguments))
        self.assertIn(secret, run.call_args.kwargs["input"])
        response = subprocess.CompletedProcess([], 0, "", "security: " + secret + ": fixture error")
        with mock.patch.object(signing.subprocess, "run", return_value=response):
            with self.assertRaises(signing.SigningError) as caught:
                signing._security(["unlock-keychain", "-p", secret, "/fixture/keychain"], secret=True)
        self.assertNotIn(secret, str(caught.exception))

    def test_security_protocol_quotes_apostrophes_and_rejects_additional_command_lines(self):
        response = subprocess.CompletedProcess([], 0, "", "")
        path = '/fixture/a\'s "keychain"\\name'
        with mock.patch.object(signing.subprocess, "run", return_value=response) as run:
            signing._security(["unlock-keychain", "-p", "fixture-password", path], secret=True)
        command = run.call_args.kwargs["input"]
        self.assertEqual(command, '"unlock-keychain" "-p" "fixture-password" "/fixture/a\'s \\"keychain\\"\\\\name"\n')
        for control in ("\n", "\r", "\x00"):
            with self.subTest(control=control), mock.patch.object(signing.subprocess, "run") as run:
                with self.assertRaises(signing.SigningError):
                    signing._security(["unlock-keychain", path + control + "delete-keychain"], secret=True)
                run.assert_not_called()
                with self.assertRaises(signing.SigningError):
                    signing.ensure(str(self.state) + control + "extra", self.identity)

    def test_command_timeout_is_fail_closed_without_logging_arguments_or_output(self):
        secret = "fixture secret"
        with mock.patch.object(signing.subprocess, "run", side_effect=subprocess.TimeoutExpired(["security", secret], 1)):
            with self.assertRaises(signing.SigningError) as caught:
                signing._run([signing.SECURITY, secret])
        self.assertNotIn(secret, str(caught.exception))

    def test_managed_setup_changes_no_trust_and_private_key_acl_is_codesign(self):
        root = self.root / "managed-build"
        root.mkdir(mode=0o700)
        signing._write_json(root / "owner.json", {"owner": signing.OWNER, "uid": os.getuid()})
        commands = []
        def security(arguments, **_kwargs):
            commands.append(arguments)
            if arguments[0] == "create-keychain":
                Path(arguments[-1]).write_bytes(b"fixture keychain")
            return "", ""
        def run(arguments, **_kwargs):
            if arguments[1] == "x509" and "-out" in arguments:
                Path(arguments[arguments.index("-out") + 1]).write_bytes(self.certificate)
            else:
                for flag in ("-keyout", "-out"):
                    if flag in arguments:
                        Path(arguments[arguments.index(flag) + 1]).write_bytes(b"fixture secret temporary")
            return "", ""
        with mock.patch.object(signing, "_security", side_effect=security), mock.patch.object(signing, "_run", side_effect=run), mock.patch.object(signing, "_available") as available, mock.patch.object(signing, "_check_signing_key"), mock.patch.object(signing, "_register_keychain") as register:
            identity, _ = signing._create_local_identity(root)
        self.assertEqual(identity, self.identity)
        imported = next(arguments for arguments in commands if arguments[0] == "import")
        self.assertEqual(imported[imported.index("-T") + 1], signing.CODESIGN)
        self.assertIn("-x", imported)
        self.assertNotIn("-A", imported)
        self.assertFalse(any(arguments[0] in ("add-trusted-cert", "remove-trusted-cert", "default-keychain", "trust-settings-import") for arguments in commands))
        register.assert_called_once_with(root / "signing.keychain-db")
        self.assertTrue((root / "setup-pending.json").exists())
        self.assertFalse(any(path.name.startswith("identity-build-") for path in root.iterdir()))
        self.assertNotIn("private-key.pem", [path.name for path in root.iterdir()])
        available.assert_called_once_with(self.identity, root / "signing.keychain-db", require_valid=False)

    def test_verify_rejects_ad_hoc_wrong_certificate_and_changed_embedded_requirement(self):
        plan, _ = self.ensure_external()
        base = {"identifier": signing.APP_ID, "identitySHA1": self.identity, "adhoc": False, "designatedRequirement": plan["designatedRequirement"]}
        for change in ({"adhoc": True}, {"identitySHA1": "A" * 40}, {"designatedRequirement": "always"}, {"identifier": "other.app"}):
            with self.subTest(change=change), mock.patch.object(signing, "inspect", return_value=base | change), mock.patch.object(signing, "_run"):
                with self.assertRaises(signing.SigningError):
                    signing.verify("fixture.app", plan)

    def test_inspect_passes_certificate_prefix_as_attached_optional_argument(self):
        app = self.root / "fixture with spaces.app"
        app.mkdir()
        def run(arguments, **_options):
            if arguments[1] == "--verify":
                self.assertEqual(arguments, [signing.CODESIGN, "--verify", "--strict", str(app)])
                return "", ""
            if arguments[2] == "--verbose=4":
                return "", "Identifier=" + signing.APP_ID + "\nSignature size=123\ndesignated => " + signing.requirement(self.identity) + "\n"
            self.assertEqual(len(arguments), 4)
            self.assertEqual(arguments[:2], [signing.CODESIGN, "--display"])
            self.assertTrue(arguments[2].startswith("--extract-certificates="))
            self.assertEqual(arguments[3], str(app))
            prefix = arguments[2].split("=", 1)[1]
            Path(prefix + "0").write_bytes(self.certificate)
            return "", ""
        with mock.patch.object(signing, "_run", side_effect=run) as run:
            inspected = signing.inspect(app)
        self.assertEqual(run.call_count, 3)
        self.assertFalse(inspected["adhoc"])
        self.assertEqual(inspected["identitySHA1"], self.identity)

    def test_verify_both_directions_of_previous_designated_requirement(self):
        plan, _ = self.ensure_external()
        current = {"identifier": signing.APP_ID, "identitySHA1": self.identity, "adhoc": False, "designatedRequirement": plan["designatedRequirement"]}
        previous = current | {"designatedRequirement": 'identifier "com.yiminlab.codex-capture" and anchor = H"' + self.identity + '"'}
        with mock.patch.object(signing, "inspect", side_effect=[current, previous]), mock.patch.object(signing, "_run") as run:
            signing.verify("new.app", plan, "old.app")
        arguments = [call.args[0] for call in run.call_args_list]
        self.assertIn([signing.CODESIGN, "--verify", "--strict", "--test-requirement", "=" + previous["designatedRequirement"], "new.app"], arguments)
        self.assertIn([signing.CODESIGN, "--verify", "--strict", "--test-requirement", "=" + current["designatedRequirement"], "old.app"], arguments)

    def test_sign_uses_exact_fingerprint_fixed_requirement_and_never_ad_hoc(self):
        plan, _ = self.ensure_external()
        app = self.root / "fixture.app"
        app.mkdir()
        with mock.patch.object(signing, "ensure", return_value=plan), mock.patch.object(signing, "_run") as run, mock.patch.object(signing, "verify", return_value={"adhoc": False}):
            result = signing.sign(app)
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[arguments.index("--sign") + 1], self.identity)
        self.assertEqual(arguments[arguments.index("--requirements") + 1], "=designated => " + plan["designatedRequirement"])
        self.assertNotEqual(arguments[arguments.index("--sign") + 1], "-")
        self.assertFalse(result["migrationRequired"])

    def test_signed_previous_identity_mismatch_is_rejected_before_signing(self):
        plan, _ = self.ensure_external()
        app = self.root / "fixture.app"
        app.mkdir()
        previous = {"identifier": signing.APP_ID, "identitySHA1": "A" * 40, "adhoc": False}
        with mock.patch.object(signing, "ensure", return_value=plan), mock.patch.object(signing, "inspect", return_value=previous), mock.patch.object(signing, "_run") as run:
            with self.assertRaisesRegex(signing.SigningError, "未签名或替换"):
                signing.sign(app, previous_app="old.app")
        run.assert_not_called()

    def test_old_ad_hoc_app_is_an_explicit_one_time_migration(self):
        plan, _ = self.ensure_external()
        app = self.root / "fixture.app"
        app.mkdir()
        previous = {"identifier": signing.APP_ID, "identitySHA1": None, "adhoc": True}
        with mock.patch.object(signing, "ensure", return_value=plan), mock.patch.object(signing, "inspect", return_value=previous), mock.patch.object(signing, "_run"), mock.patch.object(signing, "verify", return_value={"adhoc": False}):
            result = signing.sign(app, previous_app="old.app")
        self.assertTrue(result["migrationRequired"])


@unittest.skipUnless(signing.sys.platform == "darwin" and os.environ.get("CODEX_CAPTURE_TEST_SIGNING_STATE"),
                     "Opt in with an already configured private signing state on macOS")
class RealNativeSigningTests(unittest.TestCase):
    def test_changed_binaries_share_identity_and_accept_each_others_designated_requirement(self):
        """Use an existing identity; never create certificates, trust or user apps."""
        state = os.environ["CODEX_CAPTURE_TEST_SIGNING_STATE"]
        plan = signing.ensure(state)
        with tempfile.TemporaryDirectory(prefix="capture-signed-app-fixture-") as temporary:
            root = Path(temporary)
            applications = []
            for version, executable in (("1.0", "/usr/bin/true"), ("2.0", "/usr/bin/false")):
                app = root / ("Fixture-" + version + ".app")
                binary = app / "Contents/MacOS/Fixture"
                binary.parent.mkdir(parents=True)
                shutil.copyfile(executable, binary)
                binary.chmod(0o700)
                info = {"CFBundleIdentifier": signing.APP_ID, "CFBundleExecutable": "Fixture", "CFBundleName": "Synthetic signing fixture",
                        "CFBundlePackageType": "APPL", "CFBundleVersion": version, "CFBundleShortVersionString": version}
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                applications.append(app)
            first = signing.sign(applications[0], state_dir=state)
            second = signing.sign(applications[1], state_dir=state, previous_app=applications[0])
            self.assertEqual(first["identitySHA1"], plan["identitySHA1"])
            self.assertEqual(second["identitySHA1"], plan["identitySHA1"])
            self.assertEqual(first["verification"]["designatedRequirement"], second["verification"]["designatedRequirement"])
            self.assertNotEqual((applications[0] / "Contents/MacOS/Fixture").read_bytes(), (applications[1] / "Contents/MacOS/Fixture").read_bytes())
            signing.verify(applications[0], plan, previous_app=applications[1])


if __name__ == "__main__":
    unittest.main()
