"""Fail-closed replay admission for durable Core handoff receipts."""

import hashlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv/openshell_handoff"))
from files import VERSION, digest, write  # noqa: E402
from retry_verify import inspect  # noqa: E402


@pytest.fixture
def admission(tmp_path):
    submission = tmp_path / "submissions" / "source"
    root = submission / "outputs" / "runs" / "run" / ".handoff"
    producer = {
        "job_id": "job",
        "run_id": "run",
        "step_instance": "work:node",
        "attempt": 1,
        "lease_epoch": 1,
    }
    state = {
        "producer": producer,
        "phase": "prepared",
        "commit_id": "receipt",
        "request_hash": "mn.logical_request/v1:hash",
    }
    state_path = (
        root
        / "transactions"
        / digest({"run_id": "run", "step_instance": "work:node"})
        / "state.json"
    )
    write(state_path, state)
    value = {
        "trusted_root": str(tmp_path),
        "submission_path": str(submission),
        "run_ids": ["run"],
        "workflow_run_id": "run",
        "workflow": {},
        "handoff_steps": ["work:node"],
        "mode": "verify",
    }
    return value, state, state_path, root


def test_prepared_request_is_safe_but_uncertain_dispatch_is_blocked(admission):
    value, state, path, _ = admission
    assert inspect(value)["safe_handoff_steps"] == ["work:node"]
    write(path, {**state, "phase": "started"})
    assert inspect(value)["safe_handoff_steps"] == []


def test_committed_receipt_requires_matching_successful_execution(admission):
    value, state, path, root = admission
    write(path, {**state, "phase": "committed"})
    receipt = {
        "producer": state["producer"],
        "request_hash": state["request_hash"],
        "execution": {"exit_code": 0},
        "references": [],
    }
    receipt_path = root / "commits" / "receipt" / "receipt.json"
    write(receipt_path, receipt)
    assert inspect(value)["safe_handoff_steps"] == ["work:node"]
    write(receipt_path, {**receipt, "execution": {"exit_code": 7}})
    assert inspect(value)["safe_handoff_steps"] == []
    write(receipt_path, {**receipt, "request_hash": "different"})
    with pytest.raises(ValueError, match="identity mismatch"):
        inspect(value)


def test_legacy_request_digest_cannot_authorize_checkpoint_replay(admission):
    value, state, path, _ = admission
    write(path, {**state, "request_hash": "legacy-delivery-digest"})
    with pytest.raises(ValueError, match="unsupported"):
        inspect(value)


@pytest.fixture
def committed_report(admission):
    _, state, _, root = admission
    folder = root / "commits" / state["commit_id"]
    path = folder / "outputs" / "report.json"
    path.parent.mkdir(parents=True)
    content = b"saved"
    path.write_bytes(content)
    ref = {
        "type": "artifact_ref",
        "version": VERSION,
        "producer": state["producer"],
        "commit_id": state["commit_id"],
        "kind": "report",
        "path": path.name,
        "sha256": hashlib.sha256(content).hexdigest(),
        "size_bytes": len(content),
    }
    write(
        folder / "receipt.json",
        {
            "version": VERSION,
            "producer": state["producer"],
            "commit_id": state["commit_id"],
            "request_hash": state["request_hash"],
            "execution": {"exit_code": 0},
            "references": [ref],
        },
    )
    return ref, path


def test_repeated_descriptors_are_verified_once_without_reusing_checks_across_calls(
    admission, committed_report, monkeypatch
):
    import retry_verify

    value, _, _, _ = admission
    ref, path = committed_report
    value.update(workflow={"repeated": [ref] * 2000}, handoff_steps=[])
    calls = []
    original = retry_verify.resolve

    def counted(*args):
        calls.append(args)
        return original(*args)

    monkeypatch.setattr(retry_verify, "resolve", counted)
    assert inspect(value)["safe_handoff_steps"] == []
    assert len(calls) == 1
    path.write_text("other")
    with pytest.raises(ValueError, match="checksum mismatch"):
        inspect(value)


def test_reference_deduplication_does_not_ignore_conflicting_hashes(
    admission, committed_report
):
    value, _, _, _ = admission
    ref, _ = committed_report
    value.update(workflow=[ref, {**ref, "sha256": "0" * 64}], handoff_steps=[])
    with pytest.raises(ValueError, match="no matching commit receipt"):
        inspect(value)


@pytest.mark.parametrize(
    "ref",
    [
        {"kind": "report", "path": "report.json"},
        {"path": "report.json", "sha256": "0" * 64},
    ],
)
def test_unversioned_workflow_references_are_rejected(admission, ref):
    value, _, _, _ = admission
    value.update(workflow={"outputs": [ref]}, handoff_steps=[])
    with pytest.raises(ValueError, match="require artifact handoff v1"):
        inspect(value)
