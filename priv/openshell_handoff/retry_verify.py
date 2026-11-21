"""Read-only checkpoint artifact and handoff replay verification for Core."""

import json
import sys
from pathlib import Path

from files import VERSION, digest, read, regular, safe, verify
from store import resolve


def _workflow_references(value):
    """Yield versioned handoff references in workflow traversal order."""
    if isinstance(value, list):
        for child in value:
            yield from _workflow_references(child)
    elif isinstance(value, dict):
        if value.get("version") == VERSION:
            yield value
            return
        if set(value) == {"path", "sha256"} or (
            isinstance(value.get("kind"), str) and isinstance(value.get("path"), str)
        ):
            raise ValueError(
                "unsupported checkpoint artifact reference; require artifact handoff v1"
            )
        for child in value.values():
            yield from _workflow_references(child)


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

    # Inputs, outputs and delivery history may repeat the same descriptor.
    checked = set()
    for ref in _workflow_references(request["workflow"]):
        identity = digest(ref)
        if identity in checked:
            continue
        run = ref["producer"]["run_id"]
        if run not in run_roots:
            raise ValueError("cross-run artifact reference")
        resolve(run_roots[run] / ".handoff", ref)
        checked.add(identity)

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
