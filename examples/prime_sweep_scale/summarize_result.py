#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load_result(path: Path) -> dict:
    raw = path.read_text()
    decoder = json.JSONDecoder()

    for index, character in enumerate(raw):
        if character != "{":
            continue

        try:
            parsed, end_index = decoder.raw_decode(raw[index:])
        except json.JSONDecodeError:
            continue

        if not raw[index + end_index :].strip():
            return parsed

    raise json.JSONDecodeError("Could not find a single JSON document in result file", raw, 0)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: summarize_result.py <result.json>", file=sys.stderr)
        raise SystemExit(1)

    result = load_result(Path(sys.argv[1]))
    summary = {
        "job_id": result.get("job_id"),
        "status": result.get("status"),
    }

    if result.get("status") == "completed":
        summary["worker_summary"] = result["result"]["output"]
    else:
        summary["failure"] = result.get("result")

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
