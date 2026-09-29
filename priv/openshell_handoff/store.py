"""Owner-node durable transaction store, invoked exclusively by Core.

The per-step flock serializes fence changes and atomic publication. A receipt
is stored *inside* the published directory so bytes and receipt appear together.
"""
import fcntl
import json
import os
import shutil
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from files import VERSION, digest, read, references, regular, safe, sync_dir, verify, write, mkdir, validate_declarations


@contextmanager
def locked(root, identity):
    key = digest({k: identity[k] for k in ("run_id", "step_instance")})
    folder = root / "transactions" / key
    mkdir(folder)
    with (folder / "lock").open("a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield folder


def record(folder):
    path = folder / "state.json"
    return read(path) if path.exists() else None


def fence(state, identity):
    if identity["lease_epoch"] < state["fence"]:
        raise ValueError("stale lease epoch")


def receipt(root, state):
    path = root / "commits" / state["commit_id"] / "receipt.json"
    if not path.exists():
        return None
    value = read(path)
    for ref in value["references"]:
        verify(path.parent / "outputs", ref)
    return value


def resolve(root, ref):
    if ref.get("version") != VERSION:
        raise ValueError("unsupported artifact version")
    commit = safe(ref["commit_id"])
    if "/" in commit:
        raise ValueError("invalid commit ID")
    if ref["producer"]["run_id"] != root.parent.name:
        raise ValueError("cross-run artifact reference")
    if commit.startswith("input-"):
        if ref["path"] != commit[6:] + ".json" or ref["sha256"] != commit[6:]:
            raise ValueError("invalid owner input identity")
        return verify(root / "inputs", ref)
    folder = root / "commits" / commit
    committed = read(regular(folder, "receipt.json"))
    if ref not in committed["references"]:
        raise ValueError("artifact has no matching commit receipt")
    for item in committed.get("inputs", []):
        resolve(root, item)
    for item in committed["references"]:
        verify(folder / "outputs", item)
    return verify(folder / "outputs", ref)


def handle(request):
    root = Path(request["root"])
    if request.get("trusted_root") and not root.resolve().is_relative_to(Path(request["trusted_root"]).resolve()):
        raise ValueError("artifact storage escapes runtime root")
    mkdir(root)
    identity = request["identity"]
    if (identity["run_id"] != root.parent.name or not identity["step_instance"]
            or type(identity["lease_epoch"]) is not int):
        raise ValueError("invalid producer identity")
    with locked(root, identity) as folder:
        state = record(folder)
        op = request["op"]
        if op == "begin":
            if state:
                fence(state, identity)
                if state["producer"].get("owner_node") != identity.get("owner_node"):
                    raise ValueError("artifact transaction belongs to another owner node")
                if state["request_hash"] != request["request_hash"]:
                    raise ValueError("step replay input conflict")
                state["fence"] = identity["lease_epoch"]
                committed = receipt(root, state)
                if committed:
                    state.update(phase="committed", receipt=committed)
                write(folder / "state.json", state)
                return state
            commit_id = digest(identity)
            state = {"phase": "prepared", "producer": identity, "commit_id": commit_id,
                     "request_hash": request["request_hash"], "fence": identity["lease_epoch"],
                     "workspace": request["workspace"] + "/" + commit_id,
                     "sandbox": request["sandbox"], "cleanup_pending": True}
            write(folder / "state.json", state)
            return state
        if state is None:
            raise ValueError("execution transaction is missing")
        fence(state, identity)
        if op == "started":
            if state["phase"] != "prepared":
                raise ValueError("execution may already have started; explicit retry required")
            state["phase"] = "started"
        elif op == "reconcile":
            committed = receipt(root, state)
            if committed:
                state.update(phase="committed", receipt=committed)
        elif op == "prepared":
            if state["phase"] != "prepared":
                raise ValueError("cannot replace a started workspace")
            state["sandbox"] = request["sandbox"]
        elif op == "execution":
            state["execution"] = request["execution"]
            state["phase"] = "outputs_transferring"
        elif op == "inputs":
            target = Path(request["target"])
            target.mkdir(parents=True, exist_ok=True)
            index = {}
            for ref in references(request["payload"]):
                source = resolve(root, ref)
                key = ref["commit_id"] + "/" + safe(ref["path"])
                name = "files/" + ref["sha256"]
                dest = target / name
                dest.parent.mkdir(exist_ok=True)
                shutil.copyfile(source, dest)
                dest.chmod(0o444)
                index[key] = {"reference": ref, "file": name}
            write(target / "index.json", index)
            return list(entry["reference"] for entry in index.values())
        elif op == "commit":
            stage = Path(request["stage"])
            execution = request["execution"]
            manifest = read(regular(stage, "manifest.json"))
            if manifest["producer"] != state["producer"] or manifest["commit_id"] != state["commit_id"] or manifest["version"] != VERSION:
                raise ValueError("manifest producer mismatch")
            validate_declarations(execution.get("structured_result", {}))
            entries = manifest["references"]
            if any(type(r["size_bytes"]) is not int or r["size_bytes"] < 0 for r in entries) or len(entries) > request["max_files"] or sum(r["size_bytes"] for r in entries) > request["max_bytes"]:
                raise ValueError("artifact quota exceeded")
            names = set()
            for ref in entries:
                if (ref["producer"] != state["producer"] or ref["commit_id"] != state["commit_id"]
                        or ref["version"] != VERSION or ref["path"] in names):
                    raise ValueError("manifest reference mismatch")
                names.add(ref["path"])
                verify(stage / "outputs", ref)
            for ref in references(execution.get("structured_result", {})):
                if ref["commit_id"] == state["commit_id"]:
                    if ref not in entries:
                        raise ValueError("result references a missing artifact")
                else:
                    if ref not in manifest.get("inputs", []):
                        raise ValueError("result input missing from manifest")
                    resolve(root, ref)
            committed = {**manifest, "execution": execution, "request_hash": state["request_hash"]}
            destination = root / "commits" / state["commit_id"]
            mkdir(destination.parent)
            if destination.exists():
                if read(destination / "receipt.json") != committed:
                    raise ValueError("conflicting immutable commit")
                receipt(root, state)
            else:
                # Only validated files enter the publication, never a downloaded tree.
                temporary = Path(tempfile.mkdtemp(prefix=".publish-", dir=destination.parent))
                try:
                    for ref in entries:
                        src = verify(stage / "outputs", ref)
                        dst = temporary / "outputs" / safe(ref["path"])
                        mkdir(dst.parent)
                        with src.open("rb") as source, dst.open("xb") as sink:
                            shutil.copyfileobj(source, sink)
                            sink.flush()
                            os.fsync(sink.fileno())
                        dst.chmod(0o444)
                    write(temporary / "receipt.json", committed)
                    for directory, _, _ in os.walk(temporary, topdown=False):
                        sync_dir(directory)
                    os.rename(temporary, destination)
                    sync_dir(destination.parent)
                finally:
                    if temporary.exists():
                        shutil.rmtree(temporary)
            # A crash here is recovered by begin() inspecting the receipt.
            state.update(phase="committed", receipt=committed)
        elif op == "export":
            target = Path(request["target"])
            submission = root.parents[3].resolve()
            if not target.resolve().is_relative_to(submission / "outputs"):
                raise ValueError("export must stay under submission outputs")
            committed = receipt(root, state)
            if not committed or committed["execution"]["exit_code"] != 0:
                raise ValueError("only successful committed artifacts may be exported")
            exports = committed["execution"].get("structured_result", {}).get("exports", {})
            for name, ref in exports.items():
                source = resolve(root, ref)
                destination = target / safe(name)
                destination.parent.mkdir(parents=True, exist_ok=True)
                if not destination.parent.resolve().is_relative_to(target.resolve()):
                    raise ValueError("export escapes output directory")
                fd, name = tempfile.mkstemp(prefix=".export-", dir=destination.parent)
                with os.fdopen(fd, "wb") as sink, source.open("rb") as stream:
                    shutil.copyfileobj(stream, sink)
                    sink.flush()
                    os.fsync(sink.fileno())
                os.replace(name, destination)
                sync_dir(destination.parent)
            return state
        elif op == "cleanup":
            if not receipt(root, state):
                raise ValueError("cannot clean an uncommitted execution")
            owner_stage = root / "staging" / state["commit_id"]
            try:
                if owner_stage.exists():
                    shutil.rmtree(owner_stage)
                    sync_dir(owner_stage.parent)
            except OSError:
                request["warning"] = "committed artifacts retained; owner staging cleanup pending"
            state["cleanup_pending"] = bool(request.get("warning"))
            state["cleanup_warning"] = request.get("warning")
        elif op == "unknown":
            state.update(phase="unknown_blocked", error="execution outcome unknown; explicit retry required")
        else:
            raise ValueError("unknown transaction operation")
        write(folder / "state.json", state)
        return state


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": handle(read(sys.argv[1]))}))
    except Exception as error:
        print(json.dumps({"error": str(error), "kind": type(error).__name__}))
        sys.exit(1)
