"""Admit verified SDK run artifacts into a private Core handoff input index.

The source root is derived from Core's current run, never from an artifact path
or a worker environment. No SDK installation or domain code is imported here.
"""
import json
import os
import re
import tempfile

from files import VERSION, mkdir, references, safe, sync_dir, verify

JSON = "mn.committed_json/v1"
BYTES = "mn.committed_bytes/v1"


def admit(root, payload, *, max_files, max_bytes):
    found = {}
    size = 0

    def walk(value):
        nonlocal size
        if isinstance(value, dict):
            if value.get("type") == "block_artifact_bundle":
                if value.get("version") != "mn.block_handoff/v1":
                    raise ValueError("unsupported block handoff version")
                return  # Its bytes are already covered by explicit handoff refs.
            if value.get("type") == "artifact_ref" and value.get("version") in {JSON, BYTES}:
                ref = value
                if (set(ref) != {"type", "version", "path", "kind", "sha256", "size_bytes"}
                        or type(ref["size_bytes"]) is not int or ref["size_bytes"] < 0
                        or not isinstance(ref["kind"], str) or not ref["kind"]
                        or not isinstance(ref["sha256"], str)
                        or re.fullmatch(r"[a-f0-9]{64}", ref["sha256"]) is None):
                    raise ValueError("invalid committed artifact reference")
                name = safe(ref["path"])
                if ":" in name:
                    raise ValueError("unsafe committed artifact path")
                if name in found:
                    if found[name]["committed_ref"] != ref:
                        raise ValueError("conflicting committed artifact identities")
                    return
                size += ref["size_bytes"]
                if len(found) >= max_files or size > max_bytes:
                    raise ValueError("artifact input quota exceeded")
                source = verify(root.parent, ref)
                promoted = {"type": "artifact_ref", "version": VERSION,
                            "commit_id": "input-" + ref["sha256"],
                            "path": ref["sha256"] + ".json", "sha256": ref["sha256"],
                            "size_bytes": ref["size_bytes"], "kind": "committed_input",
                            "producer": {"run_id": root.parent.name, "step_instance": "owner-admission"},
                            "committed_ref": dict(ref)}
                found[name] = promoted
                destination = root / "inputs" / promoted["path"]
                mkdir(destination.parent)
                if destination.exists():
                    verify(destination.parent, promoted)
                else:
                    fd, temporary = tempfile.mkstemp(dir=destination.parent)
                    try:
                        with os.fdopen(fd, "wb") as stream:
                            stream.write(source.read_bytes())
                            stream.flush()
                            os.fsync(stream.fileno())
                        try:
                            os.link(temporary, destination)
                        except FileExistsError:
                            pass
                        verify(destination.parent, promoted)
                        sync_dir(destination.parent)
                    finally:
                        os.unlink(temporary)
                if ref["version"] == JSON:
                    walk(json.loads(verify(destination.parent, promoted).read_bytes()))
            else:
                for child in value.values():
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(payload)
    # Handoff declarations embedded inside common JSON still require receipts.
    # The promoted JSON is data; only Core resolves the inherited declarations.
    inherited = []
    for promoted in found.values():
        ref = promoted["committed_ref"]
        if ref["version"] == JSON:
            inherited.extend(references(json.loads(verify(root.parent, ref).read_bytes())))
    return [*found.values(), *inherited]
