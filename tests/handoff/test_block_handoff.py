"""Real SDK block workers against Core's private staging/seal/commit boundary."""
from dataclasses import asdict
import json
from pathlib import Path
import shutil
import sys

import pytest

HELPERS = Path(__file__).resolve().parents[2] / "priv/openshell_handoff"
SDK = Path(__file__).resolve().parents[3] / "mn-python-sdk"
sys.path.insert(0, str(HELPERS))
sys.path.insert(0, str(SDK))
for package in (SDK / "packages").glob("*/src"):
    sys.path.insert(0, str(package))

from store import handle  # noqa: E402
from worker import seal  # noqa: E402
from mn_sdk.integrations.block_worker import run  # noqa: E402
from mn_sdk.step_runtime import StepContext  # noqa: E402
from mn_sdk_common.committed_artifacts import CommittedJsonStore  # noqa: E402

INSTANCE = {"uses": "mn.blocks.domain_operation@1",
            "hooks": {"operation": "domain.probe:operation"}}


@pytest.fixture
def owner(tmp_path):
    shared = tmp_path / "submission"
    store = CommittedJsonStore(shared / "outputs/runs/run")
    return store, {"MN_JOB_SHARED_STORAGE_ROOT": str(shared), "MN_WORKFLOW_RUN_ID": "run",
                   "MN_RUN_DIR": str(store.run_dir), "MN_SDK_COMPONENTS_JSON": '["blueprint-blocks"]'}


def isolated(owner, tmp_path, step, payload, operation, *, max_bytes=64_000_000, instance=INSTANCE):
    owner_store, owner_env = owner
    root = owner_store.run_dir / ".handoff"
    identity = {"job_id": "job", "run_id": "run", "step_instance": step,
                "attempt": 1, "lease_epoch": 1}
    base = {"root": str(root), "identity": identity}
    state = handle({**base, "op": "begin", "request_hash": step,
                    "workspace": str(tmp_path / "private"), "sandbox": {}})
    workspace = Path(state["workspace"])
    inputs = handle({**base, "op": "inputs", "payload": payload,
                     "target": str(workspace / ".inputs"), "max_bytes": max_bytes})
    env = {**owner_env, "MN_JOB_SHARED_STORAGE_ROOT": str(workspace / "local"),
           "MN_RUN_DIR": str(workspace / "local/runs/run"),
           "MN_ARTIFACT_OUTPUT_DIR": str(workspace / "outputs"),
           "MN_ARTIFACT_INPUT_INDEX": str(workspace / ".inputs/index.json"),
           "MN_ARTIFACT_COMMIT_ID": state["commit_id"],
           "MN_ARTIFACT_PRODUCER": json.dumps(identity), "MN_ARTIFACT_MAX_BYTES": str(max_bytes)}
    handle({**base, "op": "started"})
    result = run(StepContext(step_id=step, run_id="run", job_id="job", agent_id=step,
                            idempotency_key="run/" + step, environment=env,
                            message={"outputs": payload}),
                 instance=instance, revision="test@1", hooks={"operation": operation} if operation else None)
    execution = {"exit_code": 0, "structured_result": asdict(result), "stdout": "", "stderr": ""}
    spec = {**state, "inputs": inputs, "max_files": 256, "max_bytes": max_bytes}
    seal(workspace, spec, execution)
    assert "seal_error" not in execution, execution
    stage = tmp_path / ("transfer-" + step)
    stage.mkdir()
    shutil.copyfile(workspace / "sealed/manifest.json", stage / "manifest.json")
    shutil.copytree(workspace / "outputs", stage / "outputs")
    committed = handle({**base, "op": "commit", "stage": str(stage), "execution": execution,
                        "max_files": 256, "max_bytes": max_bytes})
    assert committed["phase"] == "committed"
    shutil.rmtree(workspace)
    # Replay succeeds after private files have been deleted, without executing a hook.
    assert handle({**base, "op": "begin", "request_hash": step})["phase"] == "committed"
    return result


def test_host_to_sandbox_to_replacement_sandbox_to_host(owner, tmp_path):
    store, env = owner
    raw = store.commit_bytes("source/raw.bin", b"source bytes")
    source = store.commit("source/packet.json", {"file": raw.to_dict()})
    calls = []

    def analyze(block, inputs):
        assert block.store.read_bytes(inputs["source"]["file"]) == b"source bytes"
        assert block.store.run_dir != store.run_dir
        calls.append("analyze")
        case = block.store.commit("case/evidence.json", {"source": inputs["source"]["file"], "score": 7})
        return {"case": case.to_dict()}

    first = isolated(owner, tmp_path, "analyze", {"source": source.to_dict()}, analyze)
    assert not (store.run_dir / "case/evidence.json").exists()

    def review(block, inputs):
        case = block.store.read(inputs["result"]["case"])
        assert block.store.read_bytes(case["source"]) == b"source bytes"
        calls.append("review")
        return {"approved": case["score"] == 7, "evidence": inputs["result"]["case"]}

    second = isolated(owner, tmp_path, "review", first.outputs, review)

    def publish(block, inputs):
        assert inputs["result"]["approved"] is True
        case = block.store.read(inputs["result"]["evidence"])
        assert block.store.read_bytes(case["source"]) == b"source bytes"
        calls.append("publish")
        return {"status": "ready"}

    result = run(StepContext(step_id="publish", run_id="run", job_id="job", agent_id="publish",
                            idempotency_key="run/publish", environment=env, message={"outputs": second.outputs}),
                 instance=INSTANCE, revision="test@1", hooks={"operation": publish})
    assert store.read(result.outputs["result"]) == {"status": "ready"}
    assert calls == ["analyze", "review", "publish"]


@pytest.mark.parametrize("fault", ["tamper", "missing", "symlink", "escape", "quota"])
def test_bad_host_input_never_dispatches(owner, tmp_path, fault):
    store, _ = owner
    ref = store.commit_bytes("data.bin", b"trusted").to_dict()
    path = store.path(ref["path"])
    if fault == "tamper":
        path.write_bytes(b"changed")
    elif fault == "missing":
        path.unlink()
    elif fault == "symlink":
        path.unlink()
        path.symlink_to(tmp_path / "outside")
    elif fault == "escape":
        ref["path"] = "../outside"
    with pytest.raises((ValueError, OSError)):
        isolated(owner, tmp_path, "bad", {"data": ref}, lambda *_: pytest.fail("invalid input dispatched"),
                 max_bytes=1 if fault == "quota" else 64_000_000)


def test_identical_bytes_at_distinct_logical_paths_are_preserved(owner, tmp_path):
    store, _ = owner
    a = store.commit_bytes("a.bin", b"same").to_dict()
    b = store.commit_bytes("b.bin", b"same").to_dict()

    def check(block, inputs):
        assert block.store.read_bytes(inputs["a"]) == block.store.read_bytes(inputs["b"]) == b"same"
        return {"status": "ready"}

    isolated(owner, tmp_path, "same", {"a": a, "b": b}, check)


def test_stock_report_publication_uses_the_same_isolated_transport(owner, tmp_path):
    from mn_sdk.integrations.block_handoff import resolve_value

    instance = {"uses": "mn.blocks.report_publication@1", "config": {"artifacts": [
        {"id": "json", "path": "report.json", "format": "json", "required": True},
        {"id": "markdown", "path": "report.md", "format": "markdown", "required": True}]}}
    report = {"document": {"title": "Review", "sections": []}, "data": {"json": {"status": "ready"}}}
    result = isolated(owner, tmp_path, "publish", {"report": report}, None, instance=instance)
    store, env = owner
    published = resolve_value(result.outputs["result"], store, env)
    assert published["warnings"] == []
    assert json.loads(store.path("report.json").read_text()) == {"status": "ready"}
    assert "# Review" in store.path("report.md").read_text()
    later = {**env, "MN_WORKFLOW_RUN_ID": "later-run"}
    with pytest.raises(ValueError):
        resolve_value(result.outputs["result"], store, later)
    assert resolve_value(result.outputs["result"], store, later, run_id="run") == published
