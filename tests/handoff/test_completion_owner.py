"""Host and worker UIDs may differ even on the same shared mount."""
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv/openshell_handoff"))
from completion_fence import handoff_to_volume_owner


def volume(tmp_path, monkeypatch):
    run = tmp_path / "submissions/job/outputs/runs/run"
    run.mkdir(parents=True)
    owner = os.getuid() + 1
    original = Path.stat
    monkeypatch.setattr(Path, "stat", lambda path, **kw:
                        SimpleNamespace(st_uid=owner, st_gid=os.getgid())
                        if path == tmp_path else original(path, **kw))
    transfers = {}
    monkeypatch.setattr(os, "fchown", lambda fd, uid, gid:
                        transfers.update({os.fstat(fd).st_ino: (uid, gid)}))
    return run, owner, transfers


def test_fenced_inventory_transfers_private_outputs_without_changing_modes(tmp_path, monkeypatch):
    run, owner, transfers = volume(tmp_path, monkeypatch)
    private_folder = run / "evidence"
    private_folder.mkdir(mode=0o700)
    journal = run / ".handoff/receipt"
    journal.parent.mkdir()
    published = run.parent.parent / "user/report.md"
    published.parent.mkdir()
    snapshot = private_folder / "snapshot.json"
    public_report = run / "report.md"
    for path in (snapshot, public_report, published, journal):
        path.write_text("fixture")
        path.chmod(0o644 if path == public_report else 0o600)
    handoff_to_volume_owner(tmp_path, run, [{"path": str(p)} for p in (snapshot, published, public_report, journal)])
    assert transfers == {path.stat().st_ino: (owner, -1) for path in (snapshot, private_folder, published)}
    assert snapshot.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("link", ["hard", "symbolic"])
def test_other_inodes_cannot_be_reowned_through_a_publication_link(tmp_path, monkeypatch, link):
    run, _, transfers = volume(tmp_path, monkeypatch)
    outside = tmp_path / "unrelated"
    outside.write_bytes(b"private")
    outside.chmod(0o600)
    target = run / "entry"
    if link == "hard":
        os.link(outside, target)
    else:
        target.symlink_to(outside)
    with pytest.raises((ValueError, PermissionError)):
        handoff_to_volume_owner(tmp_path, run, [{"path": str(target)}])
    assert outside.stat().st_ino not in transfers
