#!/usr/bin/env python3
"""Check tracked public sources and build a deliberately small runtime archive.

Uses only the standard library and Git. Working-tree bytes are read only for
paths already in the index; untracked and ignored local data never enter a zip.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


PLUGIN = "plugins/codex-capture/"
PACKAGE_FILES = frozenset({
    "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "install.sh",
    ".agents/plugins/marketplace.json",
    PLUGIN + "LICENSE", PLUGIN + "plugin.json",
    PLUGIN + "native/CaptureApp.swift", PLUGIN + "native/Info.plist",
    PLUGIN + "scripts/capture.py", PLUGIN + "scripts/gui.py",
    PLUGIN + "skills/capture-task/SKILL.md",
    PLUGIN + "web/index.html", PLUGIN + "web/THIRD_PARTY_NOTICES.txt",
})
WEB_PREFIX = PLUGIN + "web/"
WEB_ASSET = re.compile(re.escape(WEB_PREFIX) + r"assets/index-[A-Za-z0-9_-]+\.(?:js|css)")
PRIVATE_PARTS = {
    ".git", ".local", "dist", "node_modules", ".venv", "__pycache__",
    "test-results", "playwright-report", "jobs", "captures", "screenshots",
    "task-state", "logs", ".codex", ".config", ".ssh", ".aws",
}
PRIVATE_NAMES = {
    "followup.txt", "request.json", "state.json", "context.json", "route.json",
    "diagnostics.json", "gui-server.json", "gui-endpoint.json",
    "installation.json", "hotkey-status.json", "auth.json", "id_rsa", "id_ed25519",
}
PRIVATE_SUFFIXES = {
    ".log", ".jsonl", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic",
    ".tiff", ".bmp", ".sqlite", ".sqlite3", ".db", ".zip", ".gz", ".tgz",
    ".har", ".map", ".pyc", ".pem", ".key", ".p12", ".pfx", ".bundle",
}
HOME_PATH = re.compile(rb"/(?:Users|home)/([A-Za-z0-9_.-]+)/")
EXAMPLE_USERS = {b"example", b"user", b"username", b"demo", b"test"}
SECRET_PATTERNS = (
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(rb"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b"),
    re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
)
SOURCE_MAP = re.compile(rb"(?:/[/\*][#@])\s*sourceMappingURL\s*=")


class ReleaseCheckError(Exception):
    """Only relative paths and categories are safe to include in this error."""

    def __init__(self, issues):
        self.issues = sorted(set(issues))
        super().__init__("\n".join(f"{path}: {category}" for path, category in self.issues))


def configured_followup():
    explicit = os.environ.get("CODEX_CAPTURE_FOLLOWUP_FILE")
    if explicit:
        return Path(explicit).expanduser()
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))).expanduser()
    return config / "codex-capture/followup.txt"


def private_preset_patterns(path):
    """Compare the one configured local file without printing its contents/path."""
    try:
        if not path.exists():
            return ()
        if not path.is_file() or path.stat().st_size > 64 * 1024:
            raise ValueError
        data = path.read_bytes()
    except (OSError, ValueError):
        raise ReleaseCheckError([("<local follow-up configuration>", "cannot verify private preset")]) from None
    if len(data) < 16 or not data.strip():
        return ()
    patterns = {data}
    try:
        text = data.decode("utf-8")
        # Catch the same original text embedded as a Python or JSON string.
        patterns.add(json.dumps(text, ensure_ascii=False)[1:-1].encode("utf-8"))
        patterns.add(repr(text)[1:-1].encode("utf-8"))
    except UnicodeDecodeError:
        pass
    return tuple(patterns)


def tracked_entries(root):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--stage", "-z"], cwd=root,
        capture_output=True, check=False,
    )
    if result.returncode:
        raise ReleaseCheckError([("<repository>", "cannot read Git index")])
    entries = {}
    issues = []
    for record in result.stdout.split(b"\0"):
        if not record:
            continue
        metadata, raw_name = record.split(b"\t", 1)
        mode, _object_id, stage = metadata.decode("ascii").split()
        name = os.fsdecode(raw_name)
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts:
            issues.append(("<index entry>", "unsafe path"))
            continue
        if stage != "0":
            issues.append((name, "unmerged index entry"))
        if mode not in {"100644", "100755"}:
            issues.append((name, "symlink or unsupported Git entry"))
        entries[name] = mode
    if issues:
        raise ReleaseCheckError(issues)
    return entries


def package_path(name):
    return name in PACKAGE_FILES or WEB_ASSET.fullmatch(name) is not None


def check_sources(root, followup_path=None):
    """Return audited bytes and executable modes, ready for race-free packaging."""
    root = Path(root).resolve()
    entries = tracked_entries(root)
    presets = private_preset_patterns(configured_followup() if followup_path is None else Path(followup_path))
    issues = []
    sources = {}
    for name, mode in entries.items():
        relative = PurePosixPath(name)
        basename = relative.name
        if (set(relative.parts) & PRIVATE_PARTS or basename in PRIVATE_NAMES
                or basename.startswith("VALIDATION")
                or (basename.startswith(".env") and basename != ".env.example")
                or relative.suffix.lower() in PRIVATE_SUFFIXES):
            issues.append((name, "runtime data or private file type"))
        if name.startswith(PLUGIN) and not package_path(name):
            issues.append((name, "unknown plugin file; review the release allowlist"))
        path = root / name
        if any(root.joinpath(*relative.parts[:end]).is_symlink() for end in range(1, len(relative.parts) + 1)):
            issues.append((name, "working-tree symlink"))
            continue
        try:
            if not stat.S_ISREG(path.stat().st_mode):
                raise ValueError
            data = path.read_bytes()
        except (OSError, ValueError):
            issues.append((name, "tracked file missing or unreadable"))
            continue
        if any(match.group(1) not in EXAMPLE_USERS for match in HOME_PATH.finditer(data)):
            issues.append((name, "personal home path"))
        if any(pattern.search(data) for pattern in SECRET_PATTERNS):
            issues.append((name, "credential or private key pattern"))
        if SOURCE_MAP.search(data):
            issues.append((name, "source map reference"))
        if any(pattern in data for pattern in presets):
            issues.append((name, "local private preset copied into public source"))
        sources[name] = (data, mode)
    for missing in PACKAGE_FILES - entries.keys():
        issues.append((missing, "required release file is not tracked"))
    if issues:
        raise ReleaseCheckError(issues)
    try:
        version = json.loads(sources[PLUGIN + "plugin.json"][0])["version"]
        if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", version):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise ReleaseCheckError([(PLUGIN + "plugin.json", "invalid release version")]) from None
    return sources, version


def build_archive(root, sources, version):
    output = Path(root) / "dist" / f"codex-capture-{version}.zip"
    if output.parent.is_symlink():
        raise ReleaseCheckError([("dist/", "archive output directory is a symlink")])
    output.parent.mkdir(exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".capture-release-", suffix=".tmp", dir=output.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, (data, mode) in sorted(sources.items()):
                if not package_path(name):
                    continue
                info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (0o100755 if mode == "100755" else 0o100644) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="audit tracked sources without creating an archive")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        sources, version = check_sources(root)
        if args.check:
            print(f"Release check passed: {len(sources)} tracked files.")
        else:
            output = build_archive(root, sources, version)
            print(f"Release check passed: {len(sources)} tracked files; created {output.relative_to(root)}")
    except ReleaseCheckError as exc:
        print(f"Release check failed:\n{exc}", file=sys.stderr)
        return 1
    except OSError:
        print("Release check failed: cannot write the release archive", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
