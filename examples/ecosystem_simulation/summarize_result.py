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
    raise ValueError("could not find JSON payload in result file")


def main() -> None:
    result_path = Path(sys.argv[1])
    result = decode_first_json(result_path.read_text())
    output = result.get("result", {}).get("output") or {}
    chart_only = len(sys.argv) > 2 and sys.argv[2] == "--chart-only"

    chart = render_population_chart(output.get("population_timeline") or [])

    if chart_only:
        print(chart)
        return

    print(
        json.dumps(
            {
                "job_id": result.get("job_id"),
                "status": result.get("status"),
                "simulation": output,
            },
            indent=2,
        )
    )


def render_population_chart(timeline: list[dict], width: int = 60, height: int = 10) -> str:
    if not timeline:
        return "Population chart unavailable."

    samples = sample_timeline(timeline, width)
    populations = [int(entry.get("population", 0)) for entry in samples]
    ticks = [int(entry.get("tick", 0)) for entry in samples]
    max_population = max(populations) if populations else 0
    start_population = int(timeline[0].get("population", 0))
    end_population = int(timeline[-1].get("population", 0))
    peak_population = max(int(entry.get("population", 0)) for entry in timeline)

    if max_population <= 0:
        return "\n".join(
            [
                "World Population Chart",
                "----------------------",
                "y-axis: population",
                "x-axis: time (ticks)",
                "(population remained at zero)",
            ]
        )

    grid: list[str] = []
    for row in range(height, 0, -1):
        threshold = max_population * row / height
        line = "".join("*" if population >= threshold else " " for population in populations)
        label = f"{int(round(threshold)):>4} |"
        grid.append(label + line)

    axis = "     +" + "-" * len(samples)
    tick_line = f"      {ticks[0]:<6}{' ' * max(len(samples) - 14, 1)}{ticks[-1]:>6}"

    return "\n".join(
        [
            "World Population Chart",
            "----------------------",
            f"start={start_population} peak={peak_population} end={end_population}",
            "y-axis: population",
            *grid,
            axis,
            "x-axis: time (ticks)",
            tick_line,
        ]
    )


def sample_timeline(timeline: list[dict], width: int) -> list[dict]:
    if len(timeline) <= width:
        return timeline

    sampled = []
    for index in range(width):
        position = round(index * (len(timeline) - 1) / (width - 1))
        sampled.append(timeline[position])
    return sampled


if __name__ == "__main__":
    main()
