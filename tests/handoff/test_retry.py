"""Fail-closed replay admission for durable Core handoff receipts."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv/openshell_handoff"))
from files import digest, write  # noqa: E402
from retry_verify import inspect  # noqa: E402


@pytest.fixture
def admission(tmp_path):
    submission = tmp_path / "submissions" / "source"
    root = submission / "outputs" / "runs" / "run" / ".handoff"
    producer = {"job_id": "job", "run_id": "run", "step_instance": "work:node", "attempt": 1, "lease_epoch": 1}
    state = {"producer": producer, "phase": "prepared", "commit_id": "receipt",
             "request_hash": "mn.logical_request/v1:hash"}
    state_path = root / "transactions" / digest({"run_id": "run", "step_instance": "work:node"}) / "state.json"
    write(state_path, state)
    value = {"trusted_root": str(tmp_path), "submission_path": str(submission), "run_ids": ["run"],
             "workflow_run_id": "run", "workflow": {}, "handoff_steps": ["work:node"], "mode": "verify"}
    return value, state, state_path, root


def test_prepared_request_is_safe_but_uncertain_dispatch_is_blocked(admission):
    value, state, path, _ = admission
    assert inspect(value)["safe_handoff_steps"] == ["work:node"]
    write(path, {**state, "phase": "started"})
    assert inspect(value)["safe_handoff_steps"] == []


def test_committed_receipt_requires_matching_successful_execution(admission):
    value, state, path, root = admission
    write(path, {**state, "phase": "committed"})
    receipt = {"producer": state["producer"], "request_hash": state["request_hash"],
               "execution": {"exit_code": 0}, "references": []}
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
