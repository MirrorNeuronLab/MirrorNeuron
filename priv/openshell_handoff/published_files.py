"""Core-owned materialization of accepted event publication receipts.

No SDK or domain imports. Paths come from Core's physical run, never the worker.
All receipts and bytes verify before any public file is replaced.
"""
import json
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile

from files import mkdir, regular, safe, sync_dir, verify
from store import resolve

MAX_FILES = 10000
MAX_BYTES = 64 * 1024 * 1024
COMMON = {"mn.committed_json/v1", "mn.committed_bytes/v1"}


def common(ref):
    if (not isinstance(ref, dict)
            or set(ref) != {"type", "version", "kind", "path", "size_bytes", "sha256"}
            or ref["type"] != "artifact_ref" or ref["version"] not in COMMON
            or not isinstance(ref["kind"], str) or not ref["kind"]
            or type(ref["size_bytes"]) is not int or not 0 <= ref["size_bytes"] <= MAX_BYTES
            or not isinstance(ref["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", ref["sha256"])):
        raise ValueError("invalid published reference")
    safe(ref["path"])
    return json.dumps(ref, sort_keys=True)


def contained(root, trusted):
    root, trusted = Path(root), Path(trusted).resolve()
    if not root.is_absolute() or root.is_symlink() or not root.resolve().is_relative_to(trusted):
        raise ValueError("publication storage escapes owner scope")
    for part in [root, *root.parents]:
        if part.resolve() == trusted:
            break
        if part.is_symlink():
            raise ValueError("publication storage contains a symlink")
    return root


def destination(root, name):
    path = root / safe(name)
    for part in [path, *path.parents]:
        if part == root:
            break
        if part.is_symlink():
            raise ValueError("publication destination contains a symlink")
    return path


def inventory(run, publication, bundle):
    if (not isinstance(publication, dict)
            or set(publication) != {"schema_version", "files", "receipts", "warnings"}
            or publication["schema_version"] != "mn.published_files/v1"
            or not isinstance(publication["files"], dict) or len(publication["files"]) > MAX_FILES
            or not isinstance(publication["receipts"], list) or not 1 <= len(publication["receipts"]) <= MAX_FILES):
        raise ValueError("invalid publication manifest")
    transported = {}
    if bundle is not None:
        if (not isinstance(bundle, dict) or bundle.get("type") != "block_artifact_bundle"
                or bundle.get("version") != "mn.block_handoff/v1"
                or not isinstance(bundle.get("files"), list) or len(bundle["files"]) > MAX_FILES):
            raise ValueError("invalid publication transport")
        for item in bundle["files"]:
            if not isinstance(item, dict) or set(item) != {"committed", "artifact"}:
                raise ValueError("invalid publication transport entry")
            key = common(item["committed"])
            if key in transported or (item["artifact"].get("sha256"), item["artifact"].get("size_bytes")) != (
                    item["committed"]["sha256"], item["committed"]["size_bytes"]):
                raise ValueError("publication transport identity differs")
            transported[key] = item["artifact"]
    resolved, paths, commits, total = {}, {}, {}, 0

    def transported_file(ref):
        commit = safe(ref["commit_id"])
        if "/" in commit:
            raise ValueError("invalid transport commit")
        root = run / ".handoff"
        if commit.startswith("input-") or commit not in commits:
            path = resolve(root, ref)
            if not commit.startswith("input-"):
                commits[commit] = {json.dumps(item, sort_keys=True) for item in
                    json.loads(regular(root / "commits" / commit, "receipt.json").read_bytes())["references"]}
            return path
        if json.dumps(ref, sort_keys=True) not in commits[commit]:
            raise ValueError("transport reference has no matching receipt")
        return verify(root / "commits" / commit / "outputs", ref)

    def read_reference(ref):
        nonlocal total
        key = common(ref)
        if ref["path"] in paths and paths[ref["path"]] != key:
            raise ValueError("conflicting publication references")
        paths[ref["path"]] = key
        if key not in resolved:
            total += ref["size_bytes"]
            if len(resolved) >= MAX_FILES or total > MAX_BYTES:
                raise ValueError("publication quota exceeded")
            if bundle is not None:
                if key not in transported:
                    raise ValueError("publication reference is absent from committed transport")
                source = transported_file(transported[key])
            else:
                source = verify(run, ref)
            body = source.read_bytes()
            if len(body) != ref["size_bytes"] or hashlib.sha256(body).hexdigest() != ref["sha256"]:
                raise ValueError("publication bytes changed during verification")
            resolved[key] = (source, body)
        return resolved[key]

    allowed, qualifications = {}, []
    for reference in publication["receipts"]:
        if reference.get("version") != "mn.committed_json/v1" or reference.get("kind") != "publication_receipt":
            raise ValueError("publication requires a JSON receipt")
        receipt = json.loads(read_reference(reference)[1])
        if (not isinstance(receipt, dict) or set(receipt) != {"schema_version", "plan", "artifacts", "warnings"}
                or receipt["schema_version"] != "mn.publication.v1"
                or not isinstance(receipt["plan"], list) or not 1 <= len(receipt["plan"]) <= 128
                or not isinstance(receipt["artifacts"], list) or len(receipt["artifacts"]) > 128):
            raise ValueError("invalid publication receipt")
        plan = {}
        for item in receipt["plan"]:
            if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
                    or not item["id"] or item["id"] in plan
                    or type(item.get("required")) is not bool or type(item.get("authoritative")) is not bool
                    or (item.get("mode") is not None and (type(item["mode"]) is not int or item["mode"] not in {0o600, 0o644}))
                    or (item["authoritative"] and not item["required"])):
                raise ValueError("invalid publication plan")
            safe(item["path"])
            plan[item["id"]] = item
        actual = set()
        for item in receipt["artifacts"]:
            if not isinstance(item, dict) or set(item) != {"id", "required", "reference"}:
                raise ValueError("invalid publication artifact")
            entry = plan.get(item["id"])
            ref = item["reference"]
            if (entry is None or item["id"] in actual or type(item["required"]) is not bool
                    or item["required"] != entry["required"] or ref.get("path") != entry["path"]
                    or ref.get("kind") != entry["kind"]):
                raise ValueError("publication plan differs from its artifacts")
            key = common(ref)
            read_reference(ref)
            required, mode = allowed.get(key, (False, 0o644))
            allowed[key] = (required or item["required"], mode & (entry.get("mode") or 0o600))
            actual.add(item["id"])
        if any(item["required"] and name not in actual for name, item in plan.items()):
            raise ValueError("required publication artifact is missing")
        expected = [{"code": "optional_artifact_failed", "artifact_id": name}
                    for name in plan if name not in actual]
        if receipt["warnings"] != expected:
            raise ValueError("publication receipt qualifications differ")
        qualifications.extend(receipt["warnings"])
    if publication["warnings"] != qualifications:
        raise ValueError("publication qualifications differ")
    result = []
    for name, ref in publication["files"].items():
        if not isinstance(name, str) or len(name.encode()) > 1024:
            raise ValueError("invalid publication output name")
        safe(name)
        if (name.split("/", 1)[0].startswith(".") or name.split("/", 1)[0] == "blocks"
                or name == "artifacts/results" or name.startswith("artifacts/results/")):
            raise ValueError("publication uses a reserved runtime namespace")
        key = common(ref)
        if key not in allowed:
            raise ValueError("publication output has no matching receipt")
        source, body = read_reference(ref)
        required, mode = allowed[key]
        result.append((name, source, body, required, mode))
    return result


def copy(body, target, mode):
    mkdir(target.parent)
    fd, temporary = tempfile.mkstemp(prefix=".publication-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        sync_dir(target.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def deliver(request):
    run = contained(request["run_dir"], request["trusted_root"])
    # Match Core's outputs/runs/<physical-run> convention without worker paths.
    if run.parent.name != "runs" or run.parent.parent.name != "outputs":
        raise ValueError("invalid physical run output directory")
    directories = {run}
    if request.get("output_dir"):
        directories.add(contained(request["output_dir"], run.parent.parent))
    files = inventory(run, request["publication"], request.get("handoff"))
    plans = [(name, source, body, root, destination(root, name), required, mode)
             for name, source, body, required, mode in files for root in sorted(directories)]
    warnings, failed = [], set()
    for name, source, body, root, target, required, mode in sorted(plans, key=lambda p: not p[5]):
        if source == target:
            continue
        try:
            # Recheck after creating parents, before replacing a public name.
            mkdir(target.parent)
            destination(root, name)
            copy(body, target, mode)
        except OSError:
            if required:
                raise
            if name not in failed:
                warnings.append({"code": "optional_artifact_delivery_failed", "artifact_id": name})
                failed.add(name)
    return {"warnings": warnings}


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": deliver(json.loads(Path(sys.argv[1]).read_bytes()))}))
    except Exception as error:
        # Domain/source bodies and host paths never enter runtime diagnostics.
        kind = "OSError" if isinstance(error, OSError) else type(error).__name__
        print(json.dumps({"error": "event publication failed", "kind": kind}))
        sys.exit(1)
