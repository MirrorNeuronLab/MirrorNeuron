"""Read-only checkpoint artifact and handoff replay verification for Core."""

import json
import hashlib
import sys
from pathlib import Path
from files import VERSION, digest, regular, verify, read, safe
from store import resolve


def inspect(request):
    trusted = Path(request["trusted_root"]).absolute()
    submission = Path(request["submission_path"]).absolute()
    if (
        not submission.is_relative_to(trusted)
        or submission.parent.name != "submissions"
    ):
        raise ValueError("invalid retained submission path")

    def confined(path):
        path = path.absolute()
        if not path.is_relative_to(trusted):
            raise ValueError("artifact escapes retained storage")
        for part in [path, *path.parents]:
            if part == trusted:
                break
            if part.is_symlink():
                raise ValueError("unsupported retained storage symlink")
        return path

    confined(submission)
    run_roots = {
        run: submission / "outputs" / "runs" / run for run in request["run_ids"]
    }
    if any(
        not isinstance(run, str) or safe(run) != run or "/" in run for run in run_roots
    ):
        raise ValueError("invalid retained run identity")
    for root in run_roots.values():
        confined(root / ".handoff")
    inventory = request.get("artifacts", {}).get("inventory", [])
    for entry in inventory:
        verify(confined(run_roots[entry["run_id"]]), entry)
    captured = {(entry["run_id"], entry["path"]): entry for entry in inventory}
    total_bytes = sum(entry["size_bytes"] for entry in inventory)

    def remember(root, path, run):
        nonlocal total_bytes
        relative = path.relative_to(root).as_posix()
        path = regular(confined(root), relative)
        if (run, relative) in captured:
            return
        size = path.stat().st_size
        total_bytes += size
        if len(captured) >= 10000 or total_bytes > 1000000000:
            raise ValueError("checkpoint artifact inventory exceeds its bound")
        sha = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                sha.update(chunk)
        captured[(run, relative)] = {
            "run_id": run,
            "path": relative,
            "sha256": sha.hexdigest(),
            "size_bytes": size,
        }

    # A workflow repeats the same immutable references in inputs, outputs and
    # delivery history. Verify each complete descriptor once per invocation;
    # different hashes/metadata and every later invocation remain independent.
    checked = set()

    def references(value):
        if isinstance(value, dict):
            handoff = value.get("version") == VERSION
            if not handoff and (
                set(value) == {"path", "sha256"}
                or isinstance(value.get("kind"), str)
                and isinstance(value.get("path"), str)
            ):
                raise ValueError(
                    "unsupported checkpoint artifact reference; require artifact handoff v1"
                )
            identity = digest(value) if handoff else None
            if identity in checked:
                return
            if handoff:
                run = value["producer"]["run_id"]
                if run not in run_roots:
                    raise ValueError("cross-run artifact reference")
                resolve(run_roots[run] / ".handoff", value)
            else:
                for child in value.values():
                    references(child)
            if identity is not None:
                checked.add(identity)
        elif isinstance(value, list):
            for child in value:
                references(child)

    references(request["workflow"])
    safe_steps = []
    for step in request["handoff_steps"]:
        root = run_roots[request["workflow_run_id"]] / ".handoff"
        folder = (
            root
            / "transactions"
            / digest({"run_id": request["workflow_run_id"], "step_instance": step})
        )
        state_path = folder / "state.json"
        if not state_path.exists():
            continue
        state = read(regular(confined(folder), "state.json"))
        if (
            state["producer"]["run_id"] != request["workflow_run_id"]
            or state["producer"]["step_instance"] != step
        ):
            raise ValueError("handoff producer identity mismatch")
        if not state["request_hash"].startswith("mn.logical_request/v1:"):
            raise ValueError("handoff logical replay contract is unsupported")
        if state["phase"] == "prepared":
            safe_steps.append(step)
        else:
            receipt_path = confined(
                root / "commits" / safe(state["commit_id"]) / "receipt.json"
            )
            if receipt_path.exists():
                receipt = read(regular(receipt_path.parent, "receipt.json"))
                if (
                    receipt["producer"] != state["producer"]
                    or receipt["request_hash"] != state["request_hash"]
                ):
                    raise ValueError("handoff receipt identity mismatch")
                if receipt["execution"]["exit_code"] == 0:
                    for ref in receipt["references"]:
                        resolve(root, ref)
                    safe_steps.append(step)
    return {"safe_handoff_steps": safe_steps, "inventory": list(captured.values())}


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": inspect(json.loads(Path(sys.argv[1]).read_text()))}))
    except Exception:
        # Do not expose source paths or file contents through retry diagnostics.
        print(
            json.dumps(
                {
                    "error": "Checkpoint artifacts or replay receipts are missing or invalid."
                }
            )
        )
        sys.exit(1)
