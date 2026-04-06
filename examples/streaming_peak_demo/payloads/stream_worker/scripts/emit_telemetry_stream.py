#!/usr/bin/env python3
import json
import os
from pathlib import Path


def load_input() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())


def load_context() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_CONTEXT_FILE"]).read_text())


def sample_count() -> int:
    return max(int(os.environ.get("SAMPLE_COUNT", "60")), 1)


def chunk_size() -> int:
    return max(int(os.environ.get("CHUNK_SIZE", "6")), 1)


def peak_positions(total: int) -> set[int]:
    raw = os.environ.get("PEAK_POSITIONS", "")
    if not raw.strip():
        return {max(total // 3, 1), max((total * 2) // 3, 1)}

    values = set()
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        index = int(item)
        if 1 <= index <= total:
            values.add(index)
    return values


def oscillation(index: int, jitter: int) -> int:
    return (index * 7) % max((jitter * 2) + 1, 1) - jitter


def build_samples() -> list[dict]:
    total = sample_count()
    baseline = int(os.environ.get("BASELINE", "24"))
    jitter = int(os.environ.get("JITTER", "4"))
    peak_height = int(os.environ.get("PEAK_HEIGHT", "55"))
    peaks = peak_positions(total)
    device = os.environ.get("DEVICE_ID", "sensor-alpha")

    rows = []
    for index in range(1, total + 1):
        value = baseline + oscillation(index, jitter)
        if index in peaks:
            value += peak_height

        rows.append(
            {
                "sample_index": index,
                "device_id": device,
                "metric": "throughput",
                "value": value,
                "unit": "events_per_second",
                "ts": f"sample-{index}",
            }
        )
    return rows


def encode_chunk(chunk: list[dict]) -> str:
    return "\n".join(json.dumps(item) for item in chunk) + "\n"


def main() -> None:
    load_input()
    context = load_context()
    total = sample_count()
    chunk = chunk_size()
    encoding = os.environ.get("STREAM_CONTENT_ENCODING", "gzip")
    stream_id = (
        f"{context.get('job_id', 'job')}:"
        f"{context.get('agent_id', 'agent')}:telemetry"
    )

    rows = build_samples()
    messages = []

    for seq, offset in enumerate(range(0, total, chunk), start=1):
        chunk_rows = rows[offset : offset + chunk]
        last = offset + chunk >= total
        messages.append(
            {
                "type": "telemetry_chunk",
                "body": encode_chunk(chunk_rows),
                "class": "stream",
                "content_type": "application/x-ndjson",
                "content_encoding": encoding,
                "headers": {
                    "schema_ref": "com.mirrorneuron.streaming.telemetry.chunk",
                    "schema_version": "1.0.0",
                    "stream_role": "telemetry",
                },
                "stream": {
                    "stream_id": stream_id,
                    "seq": seq,
                    "open": seq == 1,
                    "close": last,
                    "eof": last,
                },
            }
        )

    print(json.dumps({"emit_messages": messages}))


if __name__ == "__main__":
    main()
