#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load_result(path: Path) -> dict:
    raw = path.read_text()
    decoder = json.JSONDecoder()

    for index, char in enumerate(raw):
        if char != "{":
            continue
        try:
            result, _ = decoder.raw_decode(raw[index:])
            return result
        except json.JSONDecodeError:
            continue

    raise SystemExit(f"could not decode JSON result from {path}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: summarize_result.py <result.json>")

    job = load_result(Path(sys.argv[1]))
    summary = {
        "job_id": job.get("job_id"),
        "status": job.get("status"),
    }

    result = (job.get("result") or {}).get("output") or {}
    validator_blob = (result.get("sandbox") or {}).get("stdout")

    if validator_blob:
        validator = json.loads(validator_blob)
        summary["tests_passed"] = validator.get("tests_passed")
        summary["file_name"] = validator.get("file_name")
        summary["history"] = validator.get("history", [])
        summary["assertions"] = validator.get("assertions", [])
    else:
        summary["result"] = job.get("result")

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
