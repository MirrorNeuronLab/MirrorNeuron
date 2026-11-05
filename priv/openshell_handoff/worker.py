"""Sandbox execution and sealing. Persist completion before transport can fail."""

import json
import os
import sys
from pathlib import Path
from supervision import execute_command
from cache import hydrate
from files import (
    VERSION,
    read,
    references,
    sanitize,
    verify,
    write,
    validate_declarations,
)


def execute(spec):
    root = Path(spec["workspace"])
    result_path = root / "sealed" / "execution.json"
    if result_path.exists():
        return read(result_path)
    hydrate(spec)
    # An exclusive start record also fences a duplicate CLI dispatch.
    try:
        fd = os.open(root / "started", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise RuntimeError("execution outcome unknown; explicit retry required")
    os.fsync(fd)
    os.close(fd)
    (root / "outputs").mkdir(exist_ok=True)
    environment = {**os.environ, **spec["environment"]}
    captured = execute_command({**spec, "environment": environment})
    stdout = captured["stdout"]
    result = {
        "exit_code": captured["exit_code"],
        "stdout": sanitize(stdout),
        "stderr": sanitize(captured["stderr"]),
    }
    structured = root / "result.json"
    try:
        if structured.exists():
            if structured.stat().st_size > spec["max_result_bytes"]:
                raise ValueError("result quota exceeded")
            result["structured_result"] = read(structured)
        elif stdout.strip():
            result["structured_result"] = json.loads(stdout)
    except (ValueError, OSError):
        result["result_error"] = "invalid or oversized structured worker result"
    # This record survives sealing failures and is independent of transfer.
    write(root / "execution.json", result)
    seal(root, spec, result)
    return result


def seal(root, spec, result):
    entries = []
    size = 0
    try:
        validate_declarations(result.get("structured_result", {}))
        seen = set()
        upstream = []
        for ref in references(result.get("structured_result", {})):
            if ref["commit_id"] != spec["commit_id"]:
                if ref not in spec["inputs"]:
                    raise ValueError("result references an undeclared input")
                if ref not in upstream:
                    upstream.append(ref)
                continue
            if ref["producer"] != spec["producer"]:
                raise ValueError("producer identity mismatch")
            if ref["path"] in seen:
                continue
            seen.add(ref["path"])
            file = verify(root / "outputs", ref)
            size += file.stat().st_size
            if size > spec["max_bytes"] or len(seen) > spec["max_files"]:
                raise ValueError("artifact quota exceeded")
            entries.append(ref)
        if result.get("result_error"):
            raise ValueError(result["result_error"])
        # Reject unregistered files and unsupported types, including symlink dirs.
        for file in (root / "outputs").rglob("*"):
            if file.is_symlink() or (
                not file.is_dir()
                and file.relative_to(root / "outputs").as_posix() not in seen
            ):
                raise ValueError("unregistered or unsupported output")
        manifest = {
            "version": VERSION,
            "producer": spec["producer"],
            "commit_id": spec["commit_id"],
            "references": sorted(entries, key=lambda x: x["path"]),
            "inputs": upstream,
        }
        write(root / "sealed" / "manifest.json", manifest)
    except Exception as error:
        result["seal_error"] = sanitize(str(error))
    write(root / "sealed" / "execution.json", result)


if __name__ == "__main__":
    result = execute(read(sys.argv[1]))
    print("__MN_ARTIFACT_EXECUTION__" + json.dumps(result), flush=True)
