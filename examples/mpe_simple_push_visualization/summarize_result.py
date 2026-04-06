#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def decode_first_json(raw: str) -> dict:
    decoder = json.JSONDecoder()

    for index, char in enumerate(raw):
        if char != "{":
            continue
        try:
            payload, _ = decoder.raw_decode(raw[index:])
            return payload
        except json.JSONDecodeError:
            continue

    raise SystemExit("could not find a JSON payload in result output")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: summarize_result.py <result.json>")

    result_path = Path(sys.argv[1])
    job = decode_first_json(result_path.read_text())
    output = (job.get("result") or {}).get("output") or {}

    html = output.get("visualization_html", "")
    html_path = result_path.parent / "mpe_crowd_visualization.html"
    summary_path = result_path.parent / "mpe_crowd_summary.json"

    if html:
        html_path.write_text(html)

    summary = {
        "job_id": job.get("job_id"),
        "status": job.get("status"),
        "mode": output.get("mode"),
        "environment": output.get("environment"),
        "policy_mode": output.get("policy_mode"),
        "team_counts": output.get("team_counts"),
        "obstacle_count": output.get("obstacle_count"),
        "frame_count": output.get("frame_count"),
        "max_cycles": output.get("max_cycles"),
        "team_reward_averages": output.get("team_reward_averages"),
        "total_agent_collisions": output.get("total_agent_collisions"),
        "total_obstacle_contacts": output.get("total_obstacle_contacts"),
        "peak_agent_collisions": output.get("peak_agent_collisions"),
        "peak_obstacle_contacts": output.get("peak_obstacle_contacts"),
        "html_path": str(html_path) if html else None,
    }

    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
