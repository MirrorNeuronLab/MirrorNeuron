"""Real SDK receipts cross Core's accepted-event file delivery boundary."""
from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import sys
import subprocess
import builtins
import runpy
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv/openshell_handoff"))
import published_files
from files import VERSION, write
from store import handle
from mn_sdk.integrations.block_handoff import export_value
from mn_sdk.integrations.block_publication_files import publish_files
from mn_sdk_common.committed_artifacts import CommittedJsonStore
from mn_sdk_common.publication import ArtifactWrite


@pytest.fixture
def publication(tmp_path):
    run = tmp_path / "submission/outputs/runs/run-a"
    block = SimpleNamespace(root="blocks/event-a", store=CommittedJsonStore(run), check=lambda: None)
    manifest = publish_files(block, [
        ArtifactWrite("report", "reports/report.md", b"# Reviewed scene\n", kind="markdown", authoritative=True),
        ArtifactWrite("view", "views/index.html", b"<p>Reviewed scene</p>", kind="html", required=False),
    ])
    request = {"run_dir": str(run), "trusted_root": str(tmp_path),
        "output_dir": str(run.parent.parent / "user"), "publication": manifest, "handoff": None}
    return block, request


def test_completed_event_files_repair_from_the_same_sdk_receipt(publication):
    block, request = publication
    before = deepcopy(request["publication"])
    assert published_files.deliver(request) == {"warnings": []}
    for root in [block.store.run_dir, Path(request["output_dir"])]:
        assert (root / "reports/report.md").read_bytes() == b"# Reviewed scene\n"
        (root / "reports/report.md").unlink()
        (root / "views/index.html").unlink()
    assert published_files.deliver(request) == {"warnings": []}
    assert request["publication"] == before
    assert (Path(request["output_dir"]) / "reports/report.md").read_bytes() == b"# Reviewed scene\n"
    from mn_sdk.run_outputs import output_metadata
    assert [item["relative_path"] for item in output_metadata(block.store.run_dir)] == ["reports/report.md", "views/index.html"]


def test_public_inventory_is_sync_readable_without_widening_private_receipts(publication):
    from output_index import INDEX, VERSION as INDEX_VERSION

    block, request = publication
    previous = os.umask(0o077)
    try:
        private = block.store.run_dir / ".handoff/private-receipt.json"
        write(private, {"private": True})
        # Replacing an older root-only inventory must repair its readability.
        write(block.store.run_dir / INDEX, {"schema_version": INDEX_VERSION, "output_files": []})
        assert (block.store.run_dir / INDEX).stat().st_mode & 0o777 == 0o600
        published_files.deliver(request)
    finally:
        os.umask(previous)
    for root in (block.store.run_dir, Path(request["output_dir"])):
        assert (root / INDEX).stat().st_mode & 0o777 == 0o644
    assert private.stat().st_mode & 0o777 == 0o600


def test_optional_copy_failure_is_qualified_and_replay_repairs_it(publication):
    block, request = publication
    output = Path(request["output_dir"])
    output.mkdir(parents=True)
    (output / "views").write_text("unavailable optional directory")
    assert published_files.deliver(request) == {"warnings": [
        {"code": "optional_artifact_delivery_failed", "artifact_id": "views/index.html"}]}
    assert (output / "reports/report.md").read_bytes() == b"# Reviewed scene\n"
    (output / "views").unlink()
    assert published_files.deliver(request) == {"warnings": []}
    assert (output / "views/index.html").read_bytes() == b"<p>Reviewed scene</p>"


def test_required_copy_failure_preserves_the_immutable_receipt(publication):
    block, request = publication
    output = Path(request["output_dir"])
    output.mkdir(parents=True)
    (output / "reports").write_text("unavailable required directory")
    with pytest.raises(OSError):
        published_files.deliver(request)
    (output / "reports").unlink()
    assert published_files.deliver(request) == {"warnings": []}
    assert block.store.read_bytes(request["publication"]["files"]["reports/report.md"]) == b"# Reviewed scene\n"


@pytest.mark.parametrize("mode", [0o600, 0o644])
def test_declared_file_permissions_survive_delivery(tmp_path, mode):
    run = tmp_path / "submission/outputs/runs/run-a"
    block = SimpleNamespace(root="blocks/event-a", store=CommittedJsonStore(run), check=lambda: None)
    manifest = publish_files(block, [ArtifactWrite("report", "report.md", b"private report", mode=mode)])
    request = {"run_dir": str(run), "trusted_root": str(tmp_path), "publication": manifest}
    published_files.deliver(request)
    assert (run / "report.md").stat().st_mode & 0o777 == mode


@pytest.mark.parametrize("reverse", [False, True])
def test_merged_receipts_cannot_downgrade_required_or_private_files(publication, reverse):
    block, request = publication
    manifest = request["publication"]
    receipt = block.store.read(manifest["receipts"][0])
    receipt["plan"][0].update(required=False, authoritative=False, mode=0o644)
    receipt["artifacts"][0]["required"] = False
    later = block.store.commit("another/receipt.json", receipt, kind="publication_receipt").to_dict()
    manifest["receipts"].append(later)
    if reverse:
        manifest["receipts"].reverse()
    output = Path(request["output_dir"])
    output.mkdir(parents=True)
    (output / "reports").write_text("required destination unavailable")
    with pytest.raises(OSError):
        published_files.deliver(request)
    (output / "reports").unlink()
    assert published_files.deliver(request) == {"warnings": []}
    assert (output / "reports/report.md").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("fault", ["version", "files", "receipts", "receipt_version", "plan_duplicate", "plan_policy", "plan_mode", "plan_path", "artifact_duplicate", "artifact_policy", "artifact_kind", "missing_required", "invented_warning", "reference_shape", "long_name"])
def test_well_hashed_but_invalid_publication_policy_is_rejected(publication, fault):
    block, request = publication
    manifest = request["publication"]
    receipt = block.store.read(manifest["receipts"][0])
    if fault == "version":
        manifest["schema_version"] = "unknown"
    elif fault == "files":
        manifest["files"] = []
    elif fault == "receipts":
        manifest["receipts"] = []
    elif fault == "reference_shape":
        manifest["files"]["reports/report.md"] = {**manifest["files"]["reports/report.md"], "foreign": True}
    elif fault == "long_name":
        manifest["files"]["x" * 1025] = manifest["files"].pop("reports/report.md")
    else:
        if fault == "receipt_version":
            receipt["schema_version"] = "unknown"
        elif fault == "plan_duplicate":
            receipt["plan"].append(receipt["plan"][0])
        elif fault == "plan_policy":
            receipt["plan"][0]["required"] = False
        elif fault == "plan_mode":
            receipt["plan"][0]["mode"] = 0o777
        elif fault == "plan_path":
            receipt["plan"][0]["path"] = "../escape"
        elif fault == "artifact_duplicate":
            receipt["artifacts"].append(receipt["artifacts"][0])
        elif fault == "artifact_policy":
            receipt["artifacts"][0]["required"] = False
        elif fault == "artifact_kind":
            receipt["artifacts"][0]["reference"]["kind"] = "other"
        elif fault == "missing_required":
            receipt["artifacts"] = receipt["artifacts"][1:]
        else:
            receipt["warnings"] = [{"code": "invented"}]
        manifest["receipts"] = [block.store.commit("invalid/receipt.json", receipt, kind="publication_receipt").to_dict()]
    with pytest.raises(ValueError):
        published_files.deliver(request)
    assert not Path(request["output_dir"]).exists()


def test_optional_renderer_failure_keeps_the_required_report_and_qualification(publication):
    block, request = publication
    def failed():
        raise OSError("optional rendering unavailable")
    manifest = publish_files(block, [
        ArtifactWrite("report", "report.md", b"required report"),
        ArtifactWrite("view", "view.html", failed, required=False, revision="view-v1"),
    ], name="optional-rendering")
    request["publication"] = manifest
    assert manifest["warnings"] == [{"code": "optional_artifact_failed", "artifact_id": "view"}]
    assert published_files.deliver(request) == {"warnings": []}
    assert (Path(request["output_dir"]) / "report.md").read_bytes() == b"required report"
    assert not (Path(request["output_dir"]) / "view.html").exists()


@pytest.mark.parametrize("fault", ["file", "receipt", "unreceipted", "qualifications", "escape", "symlink", "missing_optional", "quota"])
def test_invalid_publication_rejects_before_any_public_copy(publication, monkeypatch, tmp_path, fault):
    block, request = publication
    manifest = request["publication"]
    if fault in {"file", "missing_optional"}:
        path = block.store.path(manifest["files"]["views/index.html"]["path"])
        if fault == "file":
            path.write_bytes(b"corrupt optional bytes")
        else:
            path.unlink()
    elif fault == "receipt":
        block.store.path(manifest["receipts"][0]["path"]).write_text("{}")
    elif fault == "unreceipted":
        manifest["files"]["reports/report.md"] = block.store.commit_bytes("unreceipted", b"private").to_dict()
    elif fault == "qualifications":
        manifest["warnings"] = [{"code": "fabricated"}]
    elif fault == "escape":
        manifest["files"]["../escape"] = manifest["files"].pop("reports/report.md")
    elif fault == "symlink":
        outside = tmp_path / "outside"
        outside.mkdir()
        (block.store.run_dir / "reports").symlink_to(outside)
    else:
        monkeypatch.setattr(published_files, "MAX_BYTES", 1)
    with pytest.raises((ValueError, OSError)):
        published_files.deliver(request)
    assert not Path(request["output_dir"]).exists()
    assert not (block.store.run_dir / "reports/report.md").exists()


def test_copy_uses_the_verified_bytes_even_if_source_changes_after_validation(publication, monkeypatch):
    block, request = publication
    source = block.store.path(request["publication"]["files"]["reports/report.md"]["path"])
    original = published_files.copy

    def mutate(body, destination, mode):
        source.write_bytes(b"changed during delivery")
        return original(body, destination, mode)

    monkeypatch.setattr(published_files, "copy", mutate)
    assert published_files.deliver(request) == {"warnings": []}
    assert (Path(request["output_dir"]) / "reports/report.md").read_bytes() == b"# Reviewed scene\n"
    with pytest.raises(ValueError):
        published_files.deliver(request)


@pytest.mark.parametrize("fault", [None, "duplicate", "hash", "commit_path", "foreign_run", "missing", "version"])
def test_private_sdk_publication_uses_committed_core_transport_after_worker_removal(tmp_path, fault):
    run = tmp_path / "submission/outputs/runs/run-a"
    identity = {"job_id": "job-a", "run_id": "run-a", "step_instance": "event-a", "attempt": 1, "lease_epoch": 1}
    base = {"root": str(run / ".handoff"), "identity": identity, "trusted_root": str(tmp_path)}
    state = handle({**base, "op": "begin", "request_hash": "event-a", "workspace": "/sandbox/attempt", "sandbox": {}})
    handle({**base, "op": "started"})
    private = tmp_path / "private-worker"
    block = SimpleNamespace(root="blocks/event-a", store=CommittedJsonStore(private), check=lambda: None)
    manifest = publish_files(block, [ArtifactWrite("report", "reports/report.md", b"# Private scene\n", kind="markdown")])
    reference = block.store.commit("blocks/event-a/result.json", {"published_files": manifest}, kind="block_result")
    wire = tmp_path / "wire"
    bundle, declarations = export_value(reference.to_dict(), block.store, {
        "MN_ARTIFACT_OUTPUT_DIR": str(wire), "MN_ARTIFACT_COMMIT_ID": state["commit_id"],
        "MN_ARTIFACT_PRODUCER": json.dumps(identity),
    })
    stage = tmp_path / "stage"
    shutil.copytree(wire, stage / "outputs")
    write(stage / "manifest.json", {"version": VERSION, "producer": identity,
        "commit_id": state["commit_id"], "references": declarations})
    handle({**base, "op": "commit", "stage": str(stage), "max_files": 256, "max_bytes": 64_000_000,
        "execution": {"exit_code": 0, "stdout": "", "stderr": "", "structured_result": {"artifacts": declarations}}})
    shutil.rmtree(private)
    shutil.rmtree(wire)
    request = {"run_dir": str(run), "trusted_root": str(tmp_path), "publication": manifest,
        "output_dir": str(run.parent.parent / "user"), "handoff": bundle}
    if fault:
        if fault == "duplicate":
            bundle["files"].append(bundle["files"][0])
        elif fault == "hash":
            bundle["files"][0]["artifact"]["sha256"] = "0" * 64
        elif fault == "commit_path":
            bundle["files"][0]["artifact"]["commit_id"] = "../escape"
        elif fault == "foreign_run":
            bundle["files"][0]["artifact"]["producer"]["run_id"] = "other-run"
        elif fault == "missing":
            bundle["files"] = []
        else:
            bundle["version"] = "unknown"
        with pytest.raises(ValueError):
            published_files.deliver(request)
        assert not (run / "reports/report.md").exists()
        return
    assert published_files.deliver(request) == {"warnings": []}
    assert (run / "reports/report.md").read_bytes() == b"# Private scene\n"
    assert not (run / "blocks").exists()  # No owner-store mount or domain re-execution.
    (run / "reports/report.md").unlink()
    assert published_files.deliver(request) == {"warnings": []}
    declaration = next(item["artifact"] for item in bundle["files"] if item["committed"] == manifest["files"]["reports/report.md"])
    committed = run / ".handoff/commits" / state["commit_id"] / "outputs" / declaration["path"]
    committed.chmod(0o644)  # Only this temporary immutable fixture is deliberately corrupted.
    committed.write_bytes(b"corrupt committed bytes")
    with pytest.raises(ValueError):
        published_files.deliver(request)


def test_owner_output_scope_is_required(publication, tmp_path):
    _, request = publication
    request["output_dir"] = str(tmp_path / "unrelated-job")
    with pytest.raises(ValueError, match="owner scope"):
        published_files.deliver(request)
    assert not (tmp_path / "unrelated-job").exists()


@pytest.mark.parametrize("name", [".handoff/commits/receipt.json", ".locks/message", "blocks/runtime/event-state.json", "artifacts/results/attempt.json", ".context/owner.json"])
def test_worker_output_cannot_replace_owner_runtime_records(publication, name):
    block, request = publication
    saved = block.store.commit_bytes(name, b"protected owner record")
    files = request["publication"]["files"]
    files[name] = files.pop("reports/report.md")
    with pytest.raises(ValueError, match="reserved"):
        published_files.deliver(request)
    assert block.store.read_bytes(saved) == b"protected owner record"
    assert not Path(request["output_dir"]).exists()


@pytest.mark.parametrize("fault", ["ancestor_link", "output_link", "wrong_run_layout", "file_quota", "byte_quota"])
def test_owner_paths_and_total_inventory_bounds_fail_before_copy(publication, monkeypatch, tmp_path, fault):
    block, request = publication
    if fault == "ancestor_link":
        link = tmp_path / "linked-submission"
        link.symlink_to(tmp_path / "submission", target_is_directory=True)
        request["run_dir"] = str(link / "outputs/runs/run-a")
    elif fault == "output_link":
        output = Path(request["output_dir"])
        output.symlink_to(block.store.run_dir, target_is_directory=True)
    elif fault == "wrong_run_layout":
        request["run_dir"] = str(tmp_path / "unscoped")
    elif fault == "file_quota":
        monkeypatch.setattr(published_files, "MAX_FILES", 2)
    else:
        manifest = request["publication"]
        monkeypatch.setattr(published_files, "MAX_BYTES", manifest["receipts"][0]["size_bytes"] + 1)
    with pytest.raises(ValueError):
        published_files.deliver(request)
    assert not (block.store.run_dir / "reports/report.md").exists()


def test_interrupted_atomic_copy_removes_temporary_files_and_can_repair(publication, monkeypatch):
    block, request = publication
    replace = published_files.os.replace
    def interrupted(*_args):
        raise OSError("copy interrupted before rename")
    monkeypatch.setattr(published_files.os, "replace", interrupted)
    with pytest.raises(OSError):
        published_files.deliver(request)
    assert not list(block.store.run_dir.rglob(".publication-*"))
    assert not (block.store.run_dir / "reports/report.md").exists()
    monkeypatch.setattr(published_files.os, "replace", replace)
    assert published_files.deliver(request) == {"warnings": []}


@pytest.mark.parametrize("failure", [False, True])
def test_standalone_helper_never_imports_sdk_or_domain_code(publication, tmp_path, monkeypatch, capsys, failure):
    _, request = publication
    if failure:
        request["publication"]["schema_version"] = "unknown"
    path = tmp_path / "standalone.json"
    path.write_text(json.dumps(request))
    original = builtins.__import__
    def isolated(name, *args, **kwargs):
        if name.startswith(("mn_sdk", "mn_blueprint_blocks", "domain")):
            raise AssertionError("Core cannot import worker code to publish files")
        return original(name, *args, **kwargs)
    monkeypatch.setattr(builtins, "__import__", isolated)
    monkeypatch.setattr(sys, "argv", [published_files.__file__, str(path)])
    if failure:
        with pytest.raises(SystemExit) as result:
            runpy.run_path(published_files.__file__, run_name="__main__")
        assert result.value.code == 1
        assert json.loads(capsys.readouterr().out)["kind"] == "ValueError"
    else:
        runpy.run_path(published_files.__file__, run_name="__main__")
        assert json.loads(capsys.readouterr().out) == {"ok": {"warnings": []}}


@pytest.mark.parametrize("failure", [False, True])
def test_core_helper_cli_contains_failures_without_private_diagnostics(publication, tmp_path, failure):
    _, request = publication
    if failure:
        request["publication"]["schema_version"] = "PRIVATE-CONTENT-MUST-NOT-BE-LOGGED"
    path = tmp_path / "request.json"
    path.write_text(json.dumps(request))
    result = subprocess.run([sys.executable, str(Path(published_files.__file__)), str(path)],
        capture_output=True, text=True, env={**os.environ}, timeout=10)
    if failure:
        assert result.returncode == 1
        assert json.loads(result.stdout) == {"error": "event publication failed", "kind": "ValueError"}
        assert "PRIVATE-CONTENT" not in result.stdout + result.stderr
    else:
        assert result.returncode == 0
        assert json.loads(result.stdout) == {"ok": {"warnings": []}}
