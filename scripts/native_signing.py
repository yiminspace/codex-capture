#!/usr/bin/env python3
"""Persistent per-user signing identity for the local macOS helper.

No private key, password, or PKCS#12 data is returned by the public API. Existing
state is pinned: missing/corrupt credentials never cause a replacement identity.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import uuid


APP_ID = "com.yiminlab.codex-capture"
OWNER = "codex-capture-native-signing-v1"
SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
OPENSSL = "/usr/bin/openssl"


class SigningError(RuntimeError):
    pass


def _run(arguments, *, input=None, timeout=30):
    try:
        result = subprocess.run(arguments, input=input, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise SigningError(f"签名工具未能完成：{Path(arguments[0]).name}。") from None
    if result.returncode:
        # Never include command arguments or security/openssl output: they can
        # contain keychain credentials even when a subordinate command fails.
        raise SigningError(f"签名工具失败：{Path(arguments[0]).name}（退出码 {result.returncode}）。")
    return result.stdout, result.stderr


def _security(arguments, *, secret=False, timeout=30):
    if any(not isinstance(argument, str) or any(character in argument for character in "\r\n\x00") for argument in arguments):
        raise SigningError("钥匙串参数包含不支持的控制字符。")
    if not secret:
        return _run([SECURITY, *arguments], timeout=timeout)
    # security's stdin command parser keeps passwords out of process argv.
    # It is not a shell: shlex's apostrophe quoting is not compatible here.
    command = " ".join('"' + argument.replace("\\", "\\\\").replace('"', '\\"') + '"' for argument in arguments)
    output, error = _run([SECURITY, "-i"], input=command + "\n", timeout=timeout)
    remaining_error = re.sub(r"security>\s*", "", error).strip()
    if remaining_error or re.search(r"security: |\bUsage: |unknown command", output):
        raise SigningError(f"专用签名钥匙串操作失败：{arguments[0]}。")
    return output, error


def _private_file(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise SigningError("签名身份文件缺失；为保留应用身份，不会自动重新生成。") from None
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SigningError("签名身份文件必须为当前用户拥有的普通文件，权限为 600。")


def _write_json(path, value):
    temporary = path.with_name(path.name + "." + secrets.token_hex(8) + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _read_json(path):
    _private_file(path)
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        raise SigningError("签名身份元数据损坏；不会覆盖或重新生成身份。") from None
    if not isinstance(value, dict):
        raise SigningError("签名身份元数据必须是对象；不会覆盖或重新生成身份。")
    return value


def _fingerprint(value):
    if not isinstance(value, str):
        raise SigningError("签名证书指纹必须是文本。")
    value = value.strip().upper()
    if not re.fullmatch(r"[0-9A-F]{40}", value):
        raise SigningError("CODEX_CAPTURE_SIGNING_IDENTITY 必须是完整的 40 位证书 SHA-1 指纹。")
    return value


def requirement(identity_sha1):
    return f'identifier "{APP_ID}" and certificate leaf = H"{_fingerprint(identity_sha1)}"'


def _normalise_requirement(value):
    value = re.sub(r'\bH"([0-9a-fA-F]{40})"', lambda item: 'H"' + item[1].upper() + '"', value)
    return " ".join(value.split())


def _identities(keychain=None, *, require_valid=True):
    arguments = ["find-identity"]
    if require_valid:
        arguments.append("-v")
    arguments += ["-p", "codesigning"]
    if keychain:
        arguments.append(str(keychain))
    output, _ = _security(arguments)
    return {match[1].upper() for match in re.finditer(r'^\s*\d+\)\s+([0-9a-fA-F]{40})\s+"', output, re.MULTILINE)}


def _available(identity_sha1, keychain=None, *, require_valid=True):
    if identity_sha1 not in _identities(keychain, require_valid=require_valid):
        raise SigningError("已固定的签名证书或私钥不可用；不会更换身份或退回临时签名。")


def _keychain_search_list():
    output, _ = _security(["list-keychains", "-d", "user"])
    try:
        paths = shlex.split(output)
    except ValueError:
        raise SigningError("无法读取用户钥匙串搜索列表，未修改。") from None
    if any(not Path(path).is_absolute() or any(character in path for character in "\r\n\x00") for path in paths):
        raise SigningError("用户钥匙串搜索列表包含无效路径，未修改。")
    return paths


def _same_keychain(first, second):
    return Path(first).resolve() == Path(second).resolve()


def _register_keychain(keychain, *, previous_keychain=None):
    """Append only our keychain, or replace only its former bootstrap path.

    Read immediately before every mutation; never restore an earlier snapshot or
    change the default keychain. Other paths retain their spelling and order.
    """
    current = _keychain_search_list()
    registered = any(_same_keychain(path, keychain) for path in current)
    updated = []
    for path in current:
        if previous_keychain is not None and _same_keychain(path, previous_keychain):
            if not registered:
                updated.append(str(keychain))
                registered = True
        else:
            updated.append(path)
    if not registered:
        updated.append(str(keychain))
    if updated != current:
        _security(["list-keychains", "-d", "user", "-s", *updated])


def _unregister_keychain(keychain):
    current = _keychain_search_list()
    updated = [path for path in current if not _same_keychain(path, keychain)]
    if updated != current:
        _security(["list-keychains", "-d", "user", "-s", *updated])


def _public_certificate(identity_sha1):
    output, _ = _security(["find-certificate", "-a", "-p"])
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", output, re.DOTALL):
        try:
            certificate = ssl.PEM_cert_to_DER_cert(pem)
        except ValueError:
            continue
        if hashlib.sha1(certificate).hexdigest().upper() == identity_sha1:
            return certificate
    raise SigningError("找不到指定签名身份的公钥证书。")


def _state_path(state_dir=None):
    value = state_dir if state_dir is not None else Path.home() / ".local/share/codex-capture/signing"
    path = Path(value).expanduser().absolute()
    if any(character in str(path) for character in "\r\n\x00"):
        raise SigningError("签名身份目录不能包含换行或空字符。")
    aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            if ancestor in aliases and ancestor.lstat().st_uid == 0 and ancestor.resolve() == aliases[ancestor]:
                continue  # Canonical macOS system aliases, outside the private base.
            raise SigningError("拒绝使用包含符号链接的签名身份目录。")
    return path


@contextlib.contextmanager
def _locked_state(state_dir=None):
    root = _state_path(state_dir)
    root.parent.mkdir(parents=True, exist_ok=True)
    lock_path = root.parent / ("." + root.name + ".lock")
    try:
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError:
        raise SigningError("无法安全打开签名身份锁文件。") from None
    try:
        _private_file(lock_path)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if root.exists():
            info = root.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise SigningError("签名身份目录必须属于当前用户，权限为 700。")
            owner = _read_json(root / "owner.json")
            if owner != {"owner": OWNER, "uid": os.getuid()}:
                raise SigningError("已有签名目录不属于此安装器，未修改。")
        yield root
    finally:
        os.close(descriptor)


def _unlock(root):
    password_path = root / "keychain-password"
    keychain = root / "signing.keychain-db"
    _private_file(password_path)
    _private_file(keychain)
    try:
        password = password_path.read_text()
    except OSError:
        raise SigningError("无法读取专用签名钥匙串凭据。") from None
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,128}", password):
        raise SigningError("专用签名钥匙串凭据损坏；不会自动重建。")
    _security(["unlock-keychain", "-p", password, str(keychain)], secret=True)
    return keychain


def _create_local_identity(root):
    """Create only in a freshly owned state directory; never rotate existing state."""
    password = secrets.token_urlsafe(48)
    password_path = root / "keychain-password"
    descriptor = os.open(password_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(password)
    keychain = root / "signing.keychain-db"
    _security(["create-keychain", "-p", password, str(keychain)], secret=True)
    os.chmod(keychain, 0o600)
    _security(["set-keychain-settings", "-l", "-u", "-t", "300", str(keychain)])
    with tempfile.TemporaryDirectory(prefix="identity-build-", dir=root) as temporary:
        stage = Path(temporary)
        config = stage / "certificate.conf"
        config.write_text("\n".join([
            "[req]", "distinguished_name=dn", "x509_extensions=code_sign", "prompt=no",
            "[dn]", "CN=Codex Capture Local Signing " + uuid.uuid4().hex,
            "[code_sign]", "basicConstraints=critical,CA:TRUE",
            "keyUsage=critical,digitalSignature,keyCertSign,cRLSign",
            "extendedKeyUsage=critical,codeSigning", "subjectKeyIdentifier=hash", "authorityKeyIdentifier=keyid:always", "",
        ]))
        private_key, pem, bundle = stage / "private-key.pem", stage / "certificate.pem", stage / "identity.p12"
        _run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
              "-config", str(config), "-keyout", str(private_key), "-out", str(pem)], timeout=90)
        os.chmod(private_key, 0o600)
        _run([OPENSSL, "x509", "-in", str(pem), "-outform", "DER", "-out", str(root / "certificate.der")])
        os.chmod(root / "certificate.der", 0o600)
        _run([OPENSSL, "pkcs12", "-export", "-inkey", str(private_key), "-in", str(pem), "-out", str(bundle), "-passout", "stdin"], input=password + "\n")
        os.chmod(bundle, 0o600)
        _security(["import", str(bundle), "-k", str(keychain), "-f", "pkcs12", "-P", password,
                   "-x", "-T", CODESIGN], secret=True)
        _security(["set-key-partition-list", "-S", "apple:", "-s", "-t", "private", "-k", password, str(keychain)], secret=True)
        certificate = (root / "certificate.der").read_bytes()
        _write_json(root / "setup-pending.json", {"identitySHA1": hashlib.sha1(certificate).hexdigest().upper(),
                                                 "certificateSHA256": hashlib.sha256(certificate).hexdigest()})
    return _complete_local_bootstrap(root)


def _check_signing_key(root, identity_sha1):
    descriptor, filename = tempfile.mkstemp(prefix="signing-probe-", dir=root)
    probe = Path(filename)
    try:
        with os.fdopen(descriptor, "wb") as destination, open("/usr/bin/true", "rb") as source:
            shutil.copyfileobj(source, destination)
        probe.chmod(0o700)
        _run([CODESIGN, "--force", "--sign", identity_sha1, "--identifier", APP_ID,
              "--requirements", "=designated => " + requirement(identity_sha1), "--timestamp=none", "--keychain", str(root / "signing.keychain-db"), str(probe)])
        _run([CODESIGN, "--verify", "--strict", "--test-requirement", "=" + requirement(identity_sha1), str(probe)])
    finally:
        probe.unlink(missing_ok=True)


def _pending_marker(root):
    markers = [root / name for name in ("setup-pending.json", "trust-pending.json") if (root / name).exists()]
    if len(markers) > 1:
        raise SigningError("发现多个未完成签名标记，未修改或重新生成身份。")
    return markers[0] if markers else None


def _complete_local_bootstrap(root):
    information = root.lstat()
    if not stat.S_ISDIR(information.st_mode) or information.st_uid != os.getuid() or information.st_mode & 0o077:
        raise SigningError("未完成的签名身份目录归属或权限无效，未修改。")
    owner = _read_json(root / "owner.json")
    if owner != {"owner": OWNER, "uid": os.getuid()} or root.is_symlink():
        raise SigningError("未完成的签名身份归属未知，未修改。")
    certificate_path = root / "certificate.der"
    _private_file(certificate_path)
    certificate = certificate_path.read_bytes()
    identity_sha1 = hashlib.sha1(certificate).hexdigest().upper()
    marker = _pending_marker(root)
    if marker is None:
        raise SigningError("未完成签名身份缺少固定证书标记，不会创建新身份。")
    pending = _read_json(marker)
    if pending.get("identitySHA1") != identity_sha1 or (pending.get("certificateSHA256") is not None and pending["certificateSHA256"] != hashlib.sha256(certificate).hexdigest()):
        raise SigningError("未完成的签名身份与原证书不匹配，不会创建新身份。")
    keychain = _unlock(root)
    _run([OPENSSL, "x509", "-inform", "DER", "-in", str(certificate_path), "-checkend", "0", "-noout"])
    _available(identity_sha1, keychain, require_valid=False)
    _register_keychain(keychain)
    # A local self-signed identity may not appear in `find-identity -v`;
    # a real signature with the pinned requirement establishes usability.
    _check_signing_key(root, identity_sha1)
    return identity_sha1, certificate


def _cleanup_bootstrap(stage):
    """Roll back only a new, unpublished identity owned by this installer."""
    owner = _read_json(stage / "owner.json")
    if owner != {"owner": OWNER, "uid": os.getuid()} or stage.is_symlink():
        raise SigningError("未完成的签名目录归属未知，未清理。")
    if _pending_marker(stage) is not None:
        raise SigningError("已固定的未完成签名身份必须保留，未清理。")
    keychain = stage / "signing.keychain-db"
    if keychain.exists():
        _private_file(keychain)
        _unregister_keychain(keychain)
        _security(["delete-keychain", str(keychain)])
    shutil.rmtree(stage)


def _bootstrap(root, requested):
    prefix = "." + root.name + "-bootstrap-"
    stages = list(root.parent.glob(prefix + "*"))
    if len(stages) > 1:
        raise SigningError("发现多个未完成的签名身份目录，请检查后恢复原身份；不会选择或重新生成。")
    stage = stages[0] if stages else None
    resuming = stage is not None and _pending_marker(stage) is not None
    if stage is not None and not resuming:
        _cleanup_bootstrap(stage)  # Only partial work before a pinned identity.
        stage = None
    if stage is None:
        certificate = None
        if requested:
            _available(requested)
            certificate = _public_certificate(requested)
        stage = Path(tempfile.mkdtemp(prefix=prefix, dir=root.parent))
        _write_json(stage / "owner.json", {"owner": OWNER, "uid": os.getuid()})
    try:
        if resuming:
            pinned = _read_json(_pending_marker(stage)).get("identitySHA1")
            if requested and requested != pinned:
                raise SigningError("指定证书与正在配置的固定身份不同，不会切换。")
            identity_sha1, certificate = _complete_local_bootstrap(stage)
            identity_type = "local-self-signed"
        elif requested:
            identity_sha1, identity_type = requested, "existing"
            certificate_path = stage / "certificate.der"
            certificate_path.write_bytes(certificate)
            certificate_path.chmod(0o600)
        else:
            identity_sha1, certificate = _create_local_identity(stage)
            identity_type = "local-self-signed"
        metadata = {"schemaVersion": 1, "owner": OWNER, "identityType": identity_type, "identitySHA1": identity_sha1,
                    "certificateSHA256": hashlib.sha256(certificate).hexdigest(), "designatedRequirement": requirement(identity_sha1),
                    "trustScope": None}
        if identity_type == "local-self-signed":
            metadata["bootstrapDirectory"] = stage.name
        _write_json(stage / "identity.json", metadata)
        if root.exists() or root.is_symlink():
            raise SigningError("签名身份目录在准备期间已存在，未覆盖。")
        stage.rename(root)
        return metadata
    except Exception as error:
        if _pending_marker(stage) is not None:
            raise SigningError("固定签名配置尚未完成，已保留同一证书和专用钥匙串；重新运行安装器将继续配置。" + str(error)) from None
        try:
            _cleanup_bootstrap(stage)
        except (OSError, SigningError):
            raise SigningError("首次签名配置未完成，专用身份清理尚未确认；请检查保留的私有准备目录后重试。") from None
        raise


def ensure(state_dir=None, identity=None, *, previous_app=None):
    """Return public signing metadata without changing any certificate trust."""
    if sys.platform != "darwin":
        raise SigningError("本机签名仅支持 macOS。")
    requested = identity if identity is not None else os.environ.get("CODEX_CAPTURE_SIGNING_IDENTITY")
    requested = _fingerprint(requested) if requested else None
    previous = inspect(previous_app) if previous_app is not None else None
    if previous and previous["identifier"] != APP_ID:
        raise SigningError("已有应用的签名标识不匹配，未配置签名身份。")
    with _locked_state(state_dir) as root:
        metadata_path = root / "identity.json"
        created = not root.exists()
        if created:
            if previous and not previous["adhoc"] and requested != previous["identitySHA1"]:
                raise SigningError("已有应用使用固定证书，但本机签名身份目录缺失；不会创建新证书。请恢复原身份，或明确提供同一证书的完整指纹。")
            metadata = _bootstrap(root, requested)
            identity_sha1 = metadata["identitySHA1"]
        else:
            metadata = _read_json(metadata_path)
            identity_sha1 = _fingerprint(metadata.get("identitySHA1", ""))
            if metadata.get("schemaVersion") != 1 or metadata.get("owner") != OWNER or metadata.get("identityType") not in ("existing", "local-self-signed"):
                raise SigningError("签名身份元数据无效，不会覆盖。")
            if metadata.get("trustScope") is not None:
                raise SigningError("签名身份的信任范围元数据无效，不会修改信任。")
            if requested and requested != identity_sha1:
                raise SigningError("指定证书与已固定身份不同；为保留系统授权，不会自动切换证书。")
            _private_file(root / "certificate.der")
            certificate = (root / "certificate.der").read_bytes()
            if (hashlib.sha1(certificate).hexdigest().upper() != identity_sha1
                    or hashlib.sha256(certificate).hexdigest() != metadata.get("certificateSHA256")
                    or metadata.get("designatedRequirement") != requirement(identity_sha1)):
                raise SigningError("签名证书或身份元数据不匹配，不会重新生成。")
        if previous and not previous["adhoc"] and previous["identitySHA1"] != identity_sha1:
            raise SigningError("已有应用与保存的签名身份不匹配，不会自动切换。")
        keychain = _unlock(root) if metadata["identityType"] == "local-self-signed" else None
        if keychain:
            _run([OPENSSL, "x509", "-inform", "DER", "-in", str(root / "certificate.der"), "-checkend", "0", "-noout"])
            bootstrap = metadata.get("bootstrapDirectory")
            if bootstrap is not None and (not isinstance(bootstrap, str) or not re.fullmatch(re.escape("." + root.name + "-bootstrap-") + r"[A-Za-z0-9_-]+", bootstrap)):
                raise SigningError("签名身份的准备目录记录无效，未修改钥匙串列表。")
            previous_keychain = root.parent / bootstrap / "signing.keychain-db" if bootstrap else None
            _register_keychain(keychain, previous_keychain=previous_keychain)
        _available(identity_sha1, keychain, require_valid=keychain is None)
        if keychain:
            _check_signing_key(root, identity_sha1)
        return {key: metadata[key] for key in ("schemaVersion", "identityType", "identitySHA1", "certificateSHA256", "designatedRequirement", "trustScope")} | {
            "keychainPath": str(keychain) if keychain else None, "metadataPath": str(metadata_path), "created": created,
            "trustStoreModified": False,
        }


def inspect(app):
    app = Path(app)
    if not app.is_dir() or app.is_symlink():
        raise SigningError("待验证应用必须是普通应用目录。")
    _run([CODESIGN, "--verify", "--strict", str(app)])
    output, error = _run([CODESIGN, "--display", "--verbose=4", "--requirements", "-", str(app)])
    combined = output + "\n" + error
    identifier = re.search(r"^Identifier=(.+)$", combined, re.MULTILINE)
    designated = re.search(r"^(?:# )?designated => (.+)$", combined, re.MULTILINE)
    adhoc = bool(re.search(r"^Signature=adhoc$", combined, re.MULTILINE))
    if not identifier or not designated:
        raise SigningError("无法读取应用的签名标识与指定要求。")
    result = {"identifier": identifier[1], "designatedRequirement": designated[1], "adhoc": adhoc, "identitySHA1": None}
    if not adhoc:
        with tempfile.TemporaryDirectory(prefix="capture-signature-") as temporary:
            prefix = str(Path(temporary) / "certificate-")
            _run([CODESIGN, "--display", "--extract-certificates=" + prefix, str(app)])
            try:
                certificate = Path(prefix + "0").read_bytes()
            except OSError:
                raise SigningError("无法提取应用的签名公钥证书。") from None
            result["identitySHA1"] = hashlib.sha1(certificate).hexdigest().upper()
    return result


def verify(app, plan, previous_app=None):
    if not isinstance(plan, dict):
        raise SigningError("签名计划无效。")
    expected = _fingerprint(plan.get("identitySHA1", ""))
    if plan.get("designatedRequirement") != requirement(expected):
        raise SigningError("签名计划中的固定要求无效。")
    current = inspect(app)
    if current["adhoc"] or current["identifier"] != APP_ID or current["identitySHA1"] != expected:
        raise SigningError("应用未使用已固定的证书与 bundle identifier 签名。")
    _run([CODESIGN, "--verify", "--strict", "--test-requirement", "=" + plan["designatedRequirement"], str(app)])
    if _normalise_requirement(current["designatedRequirement"]) != _normalise_requirement(plan["designatedRequirement"]):
        raise SigningError("应用内嵌的指定要求与固定身份不一致。")
    if previous_app is not None:
        previous = inspect(previous_app)
        if previous["identifier"] != APP_ID:
            raise SigningError("已有应用的签名标识不匹配。")
        if not previous["adhoc"]:
            if previous["identitySHA1"] != expected:
                raise SigningError("已有应用使用其他证书；不会自动迁移或替换。")
            _run([CODESIGN, "--verify", "--strict", "--test-requirement", "=" + previous["designatedRequirement"], str(app)])
            _run([CODESIGN, "--verify", "--strict", "--test-requirement", "=" + current["designatedRequirement"], str(previous_app)])
    return current


def sign(app, state_dir=None, identity=None, previous_app=None):
    plan = ensure(state_dir, identity, previous_app=previous_app)
    app = Path(app)
    if not app.is_dir() or app.is_symlink():
        raise SigningError("待签名应用必须是普通应用目录。")
    previous = inspect(previous_app) if previous_app is not None else None
    if previous and (previous["identifier"] != APP_ID or (not previous["adhoc"] and previous["identitySHA1"] != plan["identitySHA1"])):
        raise SigningError("已有应用身份与固定证书不匹配，未签名或替换。")
    arguments = [CODESIGN, "--force", "--sign", plan["identitySHA1"], "--identifier", APP_ID,
                 "--requirements", "=designated => " + plan["designatedRequirement"], "--timestamp=none"]
    if plan["keychainPath"]:
        arguments += ["--keychain", plan["keychainPath"]]
    _run([*arguments, str(app)], timeout=90)
    return plan | {"verification": verify(app, plan, previous_app), "migrationRequired": bool(previous and previous["adhoc"])}


def main():
    parser = argparse.ArgumentParser(description="Codex Capture 本机固定签名身份")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("ensure", "sign", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--state-dir")
        command.add_argument("--identity", help="已有有效签名证书的完整 SHA-1 指纹")
        if name == "ensure":
            command.add_argument("--previous-app")
        else:
            command.add_argument("--app", required=True)
        if name == "sign":
            command.add_argument("--previous-app")
    args = parser.parse_args()
    if args.command == "ensure":
        result = ensure(args.state_dir, args.identity, previous_app=args.previous_app)
    elif args.command == "sign":
        result = sign(args.app, args.state_dir, args.identity, args.previous_app)
    else:
        result = verify(args.app, ensure(args.state_dir, args.identity))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
