"""Release privacy and archive boundaries, using disposable Git repositories."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/package_release.py"
SPEC = importlib.util.spec_from_file_location("package_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capture-release-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.preset = Path(self.tmp.name) / "local-followup.txt"
        self.git("init", "-q")
        for name in release.PACKAGE_FILES:
            content = json.dumps({"version": "1.2.3"}) if name.endswith("plugin.json") else "public fixture\n"
            self.write(name, content)
        (self.root / "install.sh").chmod(0o755)
        self.write(".gitignore", "dist/\n.local/\n*.log\nfollowup.txt\n")
        self.write(release.WEB_PREFIX + "assets/index-fixture.js", "export const ready = true;\n")
        self.git("add", ".")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
        return path

    def check(self):
        return release.check_sources(self.root, self.preset)

    def assert_rejected(self, category):
        with self.assertRaises(release.ReleaseCheckError) as caught:
            self.check()
        self.assertIn(category, str(caught.exception))
        return str(caught.exception)

    def test_archive_allowlist_and_ignored_data(self):
        self.write("tests/public_test.py", "assert True\n")
        self.git("add", "tests/public_test.py")
        self.write(".local/request.json", "private request")
        self.write("followup.txt", "private followup")
        self.write(release.PLUGIN + "untracked.txt", "must never be copied")
        self.write("dist/old.zip", "old release")
        sources, version = self.check()
        output = release.build_archive(self.root, sources, version)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(set(archive.namelist()), release.PACKAGE_FILES | {release.WEB_PREFIX + "assets/index-fixture.js"})
            self.assertEqual(archive.read("README.md"), b"public fixture\n")
            self.assertTrue((archive.getinfo("install.sh").external_attr >> 16) & stat.S_IXUSR)
            self.assertFalse((archive.getinfo("README.md").external_attr >> 16) & stat.S_IXUSR)

    def test_working_tree_bytes_are_checked(self):
        self.write("README.md", "/" + "Users/real-owner/project/\n")
        message = self.assert_rejected("personal home path")
        self.assertNotIn("real-owner", message)

    def test_example_home_path_is_not_a_personal_path(self):
        self.write("README.md", "/" + "Users/example/project/\n")
        self.check()

    def test_credentials_are_rejected_without_echo(self):
        for secret in ("ghp_" + "A" * 36, "sk-proj-" + "B" * 40,
                       "-----BEGIN " + "PRIVATE KEY-----"):
            with self.subTest(kind=secret[:5]):
                self.write("README.md", secret)
                message = self.assert_rejected("credential or private key pattern")
                self.assertNotIn(secret, message)

    def test_local_preset_and_encoded_copy_are_rejected(self):
        value = "Private workflow for a local fixture\nSecond line.\n"
        self.preset.write_text(value)
        for representation in (value, json.dumps(value), repr(value)):
            with self.subTest(encoded=representation != value):
                self.write("README.md", representation)
                message = self.assert_rejected("local private preset")
                self.assertNotIn(value.strip(), message)

    def test_short_or_empty_preset_does_not_match_every_file(self):
        for value in ("", "\n", "public"):
            self.preset.write_text(value)
            self.check()

    def test_preset_location_follows_explicit_then_xdg_configuration(self):
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(Path(self.tmp.name) / "config"),
                                          "CODEX_CAPTURE_FOLLOWUP_FILE": ""}):
            self.assertEqual(release.configured_followup(), Path(self.tmp.name) / "config/codex-capture/followup.txt")
            os.environ["CODEX_CAPTURE_FOLLOWUP_FILE"] = str(self.preset)
            self.assertEqual(release.configured_followup(), self.preset)

    def test_unverifiable_preset_blocks_check_without_revealing_path(self):
        self.preset.mkdir()
        message = self.assert_rejected("cannot verify private preset")
        self.assertNotIn(str(self.preset), message)

    def test_tracked_runtime_data_is_rejected(self):
        self.write("notes.log", "private log")
        self.git("add", "-f", "notes.log")
        self.assert_rejected("runtime data or private file type")

    def test_unknown_plugin_file_is_rejected(self):
        name = release.PLUGIN + "unexpected.txt"
        self.write(name, "unreviewed file")
        self.git("add", name)
        self.assert_rejected("unknown plugin file")

    def test_arbitrary_web_text_is_not_a_release_asset(self):
        name = release.WEB_PREFIX + "note.txt"
        self.write(name, "private note")
        self.git("add", name)
        self.assert_rejected("unknown plugin file")

    def test_missing_tracked_required_file_is_rejected(self):
        self.git("rm", "--cached", "README.md")
        self.assert_rejected("required release file is not tracked")

    def test_deleted_working_tree_file_is_rejected(self):
        (self.root / "README.md").unlink()
        self.assert_rejected("tracked file missing or unreadable")

    def test_tracked_and_working_tree_symlinks_are_rejected(self):
        path = self.root / "README.md"
        path.unlink()
        path.symlink_to(self.root / "LICENSE")
        self.assert_rejected("working-tree symlink")
        self.git("add", "README.md")
        self.assert_rejected("symlink or unsupported Git entry")

    def test_source_map_reference_is_rejected(self):
        self.write(release.WEB_PREFIX + "assets/index-fixture.js", "//# " + "sourceMappingURL=fixture.js.map")
        self.assert_rejected("source map reference")

    def test_version_cannot_choose_output_path(self):
        self.write(release.PLUGIN + "plugin.json", json.dumps({"version": "../../private"}))
        self.assert_rejected("invalid release version")

    def test_archive_does_not_follow_output_directory_symlink(self):
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (self.root / "dist").symlink_to(outside, target_is_directory=True)
        sources, version = self.check()
        with self.assertRaises(release.ReleaseCheckError):
            release.build_archive(self.root, sources, version)
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
