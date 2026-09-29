"""Core handoff filesystem primitives. No third-party dependencies."""
import hashlib
import json
import os
import re
import stat
from pathlib import Path

VERSION = "mn.artifact_handoff/v1"


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mkdir(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("durable storage directory cannot be a symlink")
    if path.exists():
        return
    mkdir(path.parent)
    try:
        path.mkdir()
    except FileExistsError:
        pass
    sync_dir(path.parent)


def write(path, value):
    path = Path(path)
    mkdir(path.parent)
    temp = path.with_name(path.name + ".tmp")
    with temp.open("wb") as stream:
        stream.write(encode(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    sync_dir(path.parent)


def read(path):
    return json.loads(Path(path).read_bytes())


def safe(value):
    if (not isinstance(value, str) or not value or value.startswith("/")
            or "\\" in value or "\x00" in value
            or any(p in {"", ".", ".."} for p in value.split("/"))):
        raise ValueError("unsafe artifact path")
    return value


def regular(root, name):
    root = Path(root)
    if root.is_symlink():
        raise ValueError("artifact root cannot be a symlink")
    path = root / safe(name)
    for item in [path, *path.parents]:
        if item == root:
            break
        if item.is_symlink():
            raise ValueError("unsupported artifact symlink")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("unsupported artifact file type")
    return path


def verify(root, ref):
    path = regular(root, ref["path"])
    if path.stat().st_size != ref["size_bytes"]:
        raise ValueError("artifact size mismatch")
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    if sha.hexdigest() != ref["sha256"]:
        raise ValueError("artifact checksum mismatch")
    return path


def validate_declarations(value):
    if isinstance(value, dict):
        if "artifacts" in value:
            if not isinstance(value["artifacts"], list) or any(
                    not isinstance(ref, dict) or ref.get("type") != "artifact_ref" or ref.get("version") != VERSION
                    for ref in value["artifacts"]):
                raise ValueError("all result artifacts require versioned declarations")
        for child in value.values():
            validate_declarations(child)
    elif isinstance(value, list):
        for child in value:
            validate_declarations(child)


def references(value):
    if isinstance(value, dict):
        if value.get("type") == "artifact_ref" and value.get("version") == VERSION:
            yield value
        else:
            for child in value.values():
                yield from references(child)
    elif isinstance(value, list):
        for child in value:
            yield from references(child)


def sanitize(text, limit=65536):
    for key, value in os.environ.items():
        if value and re.search(r"TOKEN|SECRET|KEY|COOKIE|PASSWORD", key, re.I):
            text = text.replace(value, "[REDACTED]")
    return text[-limit:]
