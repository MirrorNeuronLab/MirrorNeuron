"""Deterministic crash/transfer contract tests for Core's filesystem boundary."""
import hashlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv/openshell_handoff"))
from files import VERSION, read, write
from store import handle, locked


@pytest.fixture
def transaction(tmp_path):
    root = tmp_path / "submission" / "outputs" / "runs" / "runtime-run" / ".handoff"
    identity = {"job_id": "job", "run_id": "runtime-run", "step_instance": "generate", "attempt": 1, "lease_epoch": 1}
    base = {"root": str(root), "identity": identity}
    state = handle({**base, "op": "begin", "request_hash": "request", "workspace": "/sandbox/job/attempts", "sandbox": {"sandbox_name": "old"}})
    handle({**base, "op": "started"})
    stage = tmp_path / "stage"
    (stage / "outputs").mkdir(parents=True)
    (stage / "outputs/index.html").write_bytes(b"hello")
    ref = {"type": "artifact_ref", "version": VERSION, "path": "index.html", "kind": "html", "sha256": hashlib.sha256(b"hello").hexdigest(), "size_bytes": 5, "commit_id": state["commit_id"], "producer": identity}
    manifest = {"version": VERSION, "producer": identity, "commit_id": state["commit_id"], "references": [ref]}
    write(stage / "manifest.json", manifest)
    execution = {"exit_code": 0, "stdout": "", "stderr": "", "structured_result": {"artifacts": [ref]}}
    commit = {**base, "op": "commit", "stage": str(stage), "execution": execution, "max_files": 10, "max_bytes": 100}
    return base, state, stage, ref, commit


def test_commit_and_replay(transaction):
    base, _, _, _, commit = transaction
    result = handle(commit)
    assert result["phase"] == "committed"
    assert handle(commit)["receipt"] == result["receipt"]
    assert handle({**base, "op": "begin", "request_hash": "request"})["phase"] == "committed"


def test_crash_after_publication_before_state_update(transaction):
    base, _, _, _, commit = transaction
    with locked(Path(base["root"]), base["identity"]) as folder:
        before = read(folder / "state.json")
    handle(commit)
    write(folder / "state.json", before)
    assert handle({**base, "op": "begin", "request_hash": "request"})["phase"] == "committed"


def test_started_is_never_redispatched(transaction):
    base, _, _, _, _ = transaction
    with pytest.raises(ValueError, match="already have started"):
        handle({**base, "op": "started"})
    assert handle({**base, "op": "begin", "request_hash": "request"})["phase"] == "started"


def test_stale_lease_fenced(transaction):
    base, _, _, _, commit = transaction
    handle({**base, "identity": {**base["identity"], "lease_epoch": 2}, "op": "begin", "request_hash": "request"})
    with pytest.raises(ValueError, match="stale lease"):
        handle(commit)


@pytest.mark.parametrize("fault", ["missing", "corrupt", "symlink", "quota", "count", "escape", "producer", "duplicate", "missing-reference"])
def test_invalid_set_never_published(transaction, fault):
    base, state, stage, ref, commit = transaction
    if fault == "missing":
        (stage / "outputs/index.html").unlink()
    elif fault == "corrupt":
        (stage / "outputs/index.html").write_bytes(b"wrong")
    elif fault == "symlink":
        (stage / "outputs/index.html").unlink()
        (stage / "outputs/index.html").symlink_to(stage / "manifest.json")
    elif fault == "quota":
        commit["max_bytes"] = 1
    elif fault == "count":
        commit["max_files"] = 0
    else:
        manifest = read(stage / "manifest.json")
        if fault == "escape": manifest["references"][0]["path"] = "../outside"
        if fault == "producer": manifest["producer"]["lease_epoch"] = 9
        if fault == "duplicate": manifest["references"].append(ref)
        if fault == "missing-reference": manifest["references"] = []
        write(stage / "manifest.json", manifest)
    with pytest.raises((ValueError, OSError)):
        handle(commit)
    assert not (Path(base["root"]) / "commits" / state["commit_id"]).exists()


def test_conflicting_commit_rejected(transaction):
    _, _, _, _, commit = transaction
    handle(commit)
    commit["execution"] = {**commit["execution"], "exit_code": 1}
    with pytest.raises(ValueError, match="conflicting"):
        handle(commit)


def test_replica_barrier_checks_all_bytes(transaction, tmp_path):
    base, _, _, ref, commit = transaction
    handle(commit)
    inputs = {**base, "op": "inputs", "payload": {"html": ref}, "target": str(tmp_path / "new-sandbox")}
    handle(inputs)
    published = Path(base["root"]) / "commits" / ref["commit_id"] / "outputs/index.html"
    published.unlink()
    with pytest.raises(OSError):
        handle({**inputs, "target": str(tmp_path / "another-sandbox")})


def test_cleanup_failure_keeps_commit(transaction):
    base, _, _, _, commit = transaction
    handle(commit)
    handle({**base, "op": "cleanup", "warning": "unavailable"})
    result = handle({**base, "op": "begin", "request_hash": "request"})
    assert result["phase"] == "committed" and result["cleanup_pending"]


@pytest.mark.parametrize("optional", [True, False])
def test_export_delivery_policy_and_recovery_use_committed_bytes(transaction, tmp_path, monkeypatch, optional):
    import store
    base, _, _, ref, commit = transaction
    commit["execution"]["structured_result"].update(exports={"review.html": ref},
        optional_exports=["review.html"] if optional else [])
    handle(commit)
    copy = store.shutil.copyfileobj
    monkeypatch.setattr(store.shutil, "copyfileobj", lambda *_a: (_ for _ in ()).throw(OSError("destination unavailable")))
    request = {**base, "op": "export", "target": str(tmp_path / "submission/outputs/user")}
    if optional:
        result = handle(request)
        assert result["export_warnings"] == [{"code": "optional_artifact_delivery_failed", "artifact_id": "review.html", "error_type": "OSError"}]
    else:
        with pytest.raises(OSError):
            handle(request)
    assert not list((tmp_path / "submission/outputs/user").glob(".export-*"))
    monkeypatch.setattr(store.shutil, "copyfileobj", copy)
    assert handle(request)["export_warnings"] == []
    assert (tmp_path / "submission/outputs/user/review.html").read_bytes() == b"hello"
    from mn_sdk.run_outputs import output_metadata
    run = Path(base["root"]).parent
    outputs = output_metadata(run)
    assert len(outputs) == 1 and outputs[0]["path"] == str(run / "review.html")
    assert outputs[0]["sha256"] == ref["sha256"]
    assert handle({**base, "op": "begin", "request_hash": "request"})["phase"] == "committed"


@pytest.mark.parametrize("policy", [["missing"], ["review.html", "review.html"], "review.html", [[]]])
def test_invalid_optional_export_policy_cannot_change_delivery_authority(transaction, tmp_path, policy):
    base, _, _, ref, commit = transaction
    commit["execution"]["structured_result"].update(exports={"review.html": ref}, optional_exports=policy)
    handle(commit)
    with pytest.raises(ValueError, match="export policy"):
        handle({**base, "op": "export", "target": str(tmp_path / "submission/outputs/user")})
    assert not (tmp_path / "submission/outputs/user/review.html").exists()


def test_optional_export_cannot_hide_corrupt_committed_bytes(transaction, tmp_path):
    base, _, _, ref, commit = transaction
    commit["execution"]["structured_result"].update(exports={"review.html": ref}, optional_exports=["review.html"])
    handle(commit)
    published = Path(base["root"]) / "commits" / ref["commit_id"] / "outputs/index.html"
    published.chmod(0o600)
    published.write_bytes(b"tampered")
    with pytest.raises(ValueError, match="mismatch"):
        handle({**base, "op": "export", "target": str(tmp_path / "submission/outputs/user")})


@pytest.mark.parametrize("name", [".mn-published-files.json", ".locks/runtime", "blocks/private.json", "artifacts/results/attempt.json"])
def test_exports_cannot_overwrite_runtime_index_or_private_records(transaction, tmp_path, name):
    base, _, _, ref, commit = transaction
    commit["execution"]["structured_result"]["exports"] = {name: ref}
    handle(commit)
    with pytest.raises(ValueError, match="reserved"):
        handle({**base, "op": "export", "target": str(tmp_path / "submission/outputs/user")})
    assert not (tmp_path / "submission/outputs/user").exists()
