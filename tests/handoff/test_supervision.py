"""Exercise the same stdlib-only supervisor uploaded into real sandboxes."""
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv/openshell_handoff"))
from supervision import Supervision


@pytest.fixture
def supervisor():
    clock, emitted = [0], []
    value = Supervision(300, {"MN_WORKFLOW_ATTEMPT_ID": "attempt"}, lambda: clock[0], emitted.append)
    return value, clock, emitted


def preparation(identity="model", timeout=1200000):
    return {"type": "runtime_preparation_started", "payload": {"kind": "model", "preparation_id": identity,
            "attempt_id": "attempt", "timeout_ms": timeout}}


def beacon(sequence=1, **extra):
    return {"type": "agent_beacon", "payload": {"source": "agent", "pid": 7,
            "progress_sequence": sequence, **extra}}


def test_remote_clock_excludes_only_union_of_setup_and_never_the_idle_gap(supervisor):
    value, clock, _ = supervisor
    clock[0] = 10
    value.observe(preparation("first"))
    clock[0] = 20
    value.observe(preparation("nested"))
    clock[0] = 30
    value.observe({"type": "runtime_preparation_finished", "payload": preparation("nested")["payload"]})
    clock[0] = 110
    value.observe({"type": "runtime_preparation_finished", "payload": preparation("first")["payload"]})
    clock[0] = 210
    value.observe(preparation("second"))
    clock[0] = 510
    value.observe({"type": "runtime_preparation_finished", "payload": preparation("second")["payload"]})
    assert value.deadline == 700
    clock[0] = 699
    assert not value.expired()
    clock[0] = 700
    assert value.expired()


def test_remote_stalled_preparation_keeps_its_fixed_deadline(supervisor):
    value, clock, _ = supervisor
    value.observe(preparation(timeout=10000))
    clock[0] = 9
    value.observe(preparation(timeout=10000))
    assert not value.expired()
    clock[0] = 10
    value.observe({"type": "runtime_preparation_finished", "payload": preparation()["payload"]})
    assert value.expired()


def test_remote_progress_and_bounded_wait_are_not_renewed_by_replayed_beacons(supervisor):
    value, clock, _ = supervisor
    clock[0] = 290
    value.observe(beacon())
    clock[0] = 400
    value.observe(beacon())
    assert value.deadline == 590
    value.observe(beacon(2, wait_id="request", wait_timeout_ms=900000))
    clock[0] = 1000
    value.observe(beacon(3, wait_id="request", wait_timeout_ms=900000))
    assert value.wait == 1600
    clock[0] = 1600
    assert value.expired()


@pytest.mark.parametrize("fault", [{"attempt_id": "old"}, {"source": "runtime"}, {"pid": 0},
                                  {"pid": True}, {"progress_sequence": True}, {"progress_sequence": -1}])
def test_remote_invalid_receipts_cannot_extend_execution(supervisor, fault):
    value, clock, _ = supervisor
    clock[0] = 299
    value.observe(beacon(**fault))
    clock[0] = 300
    assert value.expired()


def test_live_relay_handles_split_lines_and_hides_non_protocol_output(supervisor):
    value, clock, emitted = supervisor
    line = b"__MN_EVENT__" + json.dumps(preparation()).encode()
    value.feed(b"private tool output\n" + line[:20])
    assert emitted == []
    value.feed(line[20:] + b"\n")
    assert emitted == [line]
    clock[0] = 600
    assert not value.expired()
    value.feed(b"x" * 100000)
    assert len(value.pending) <= 16384
    value.feed(b"__MN_EVENT__invalid\n")
    assert emitted == [line]


def test_closed_pipes_do_not_bypass_remote_dead_step_detection(tmp_path):
    from supervision import execute_command
    result = execute_command({"command": [sys.executable, "-c",
        "import os,time; os.close(1); os.close(2); time.sleep(60)"],
        "workdir": str(tmp_path), "timeout_seconds": .2})
    assert result["exit_code"] != 0


def test_orphaned_pipe_holders_are_retired_instead_of_waiting_forever(tmp_path):
    from supervision import execute_command
    result = execute_command({"command": [sys.executable, "-c",
        "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])"],
        "workdir": str(tmp_path), "timeout_seconds": .2})
    assert result["exit_code"] == 124
