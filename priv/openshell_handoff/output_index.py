"""Runtime-owned mn.published_outputs/v1 projection; no SDK/domain imports."""
import fcntl
import hashlib
import json
from pathlib import Path
import re

from files import mkdir, regular, safe, verify, write

INDEX = ".mn-published-files.json"
VERSION = "mn.published_outputs/v1"
MAX_FILES = 10000
MAX_BYTES = 8 * 1024 * 1024


def public_name(name):
    safe(name)
    if (len(name.encode()) > 1024 or ":" in name
            or name.split("/", 1)[0].startswith(".") or name.split("/", 1)[0] == "blocks"
            or name == "artifacts/results" or name.startswith("artifacts/results/")):
        raise ValueError("published output uses a reserved or invalid name")
    return name


def entries(value):
    if (not isinstance(value, dict) or set(value) != {"schema_version", "output_files"}
            or value["schema_version"] != VERSION or not isinstance(value["output_files"], list)
            or len(value["output_files"]) > MAX_FILES):
        raise ValueError("invalid published output inventory")
    result = {}
    for item in value["output_files"]:
        if not isinstance(item, dict) or set(item) != {"path", "kind", "size_bytes", "sha256"}:
            raise ValueError("invalid published output entry")
        name = public_name(item["path"])
        if (name in result or not isinstance(item["kind"], str) or not item["kind"]
                or type(item["size_bytes"]) is not int or item["size_bytes"] < 0
                or not isinstance(item["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])):
            raise ValueError("invalid published output entry")
        result[name] = item
    return result


def record(directory, files):
    root = Path(directory)
    incoming = entries({"schema_version": VERSION, "output_files": [
        {"path": name, "kind": ref["kind"], "size_bytes": ref["size_bytes"], "sha256": ref["sha256"]}
        for name, ref in sorted(files.items())]})
    for item in incoming.values():
        verify(root, item)
    lock_name = hashlib.sha256(b"published-output-index/v1").hexdigest() + ".lock"
    mkdir(root / ".locks")
    lock = root / ".locks" / lock_name
    if lock.is_symlink():
        raise ValueError("published output lock cannot be a symlink")
    with lock.open("a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        previous = {}
        if (root / INDEX).exists():
            path = regular(root, INDEX)
            if path.stat().st_size > MAX_BYTES:
                raise ValueError("published output inventory exceeds size limit")
            previous = entries(json.loads(path.read_bytes()))
        merged = {**previous, **incoming}
        value = {"schema_version": VERSION, "output_files": list(merged.values())}
        entries(value)
        if len(json.dumps(value).encode()) > MAX_BYTES:
            raise ValueError("published output inventory exceeds size limit")
        write(root / INDEX, value)
