#!/usr/bin/env python3
import json
import os
import zlib
from pathlib import Path


def load_message() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_MESSAGE_FILE"]).read_text())


def load_context() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_CONTEXT_FILE"]).read_text())


def decode_samples() -> list[dict]:
    body = Path(os.environ["MIRROR_NEURON_BODY_FILE"]).read_bytes()
    encoding = os.environ.get("MIRROR_NEURON_BODY_CONTENT_ENCODING", "identity")

    if encoding == "gzip":
        raw = zlib.decompress(body, wbits=31).decode("utf-8")
    else:
        raw = body.decode("utf-8")

    return [json.loads(line) for line in raw.splitlines() if line.strip()]


def detect_peak(sample: dict, state: dict):
    recent_values = state["recent_values"]
    warmup_points = int(os.environ.get("WARMUP_POINTS", "5"))
    spike_multiplier = float(os.environ.get("SPIKE_MULTIPLIER", "2.4"))
    min_spike_delta = float(os.environ.get("MIN_SPIKE_DELTA", "20.0"))

    if len(recent_values) < warmup_points:
        return None

    baseline = sum(recent_values) / len(recent_values)
    value = sample["value"]

    if value >= baseline * spike_multiplier and value - baseline >= min_spike_delta:
        return {
            "sample_index": sample["sample_index"],
            "device_id": sample["device_id"],
            "metric": sample["metric"],
            "value": value,
            "baseline": round(baseline, 2),
            "delta": round(value - baseline, 2),
            "ts": sample["ts"],
        }

    return None


def initial_state() -> dict:
    return {
        "chunks_received": 0,
        "points_seen": 0,
        "peaks": [],
        "recent_values": [],
        "stream_id": None,
        "last_value": None,
    }


def summarize(state: dict) -> dict:
    largest_peak = max(state["peaks"], key=lambda peak: peak["value"], default=None)
    return {
        "mode": "stream_peak_detection",
        "stream_id": state["stream_id"],
        "chunks_received": state["chunks_received"],
        "points_seen": state["points_seen"],
        "anomaly_detected": bool(state["peaks"]),
        "peak_count": len(state["peaks"]),
        "largest_peak": largest_peak,
        "peaks": state["peaks"],
        "last_value": state["last_value"],
    }


def main() -> None:
    message = load_message()
    context = load_context()
    state = context.get("agent_state") or initial_state()
    samples = decode_samples()
    events = []

    if state["stream_id"] is None:
        state["stream_id"] = message.get("stream", {}).get("stream_id")

    for sample in samples:
        peak = detect_peak(sample, state)
        if peak is not None:
            state["peaks"].append(peak)
            events.append({"type": "stream_peak_detected", "payload": peak})

        state["recent_values"].append(sample["value"])
        window_size = int(os.environ.get("WINDOW_SIZE", "8"))
        state["recent_values"] = state["recent_values"][-window_size:]
        state["points_seen"] += 1
        state["last_value"] = sample["value"]

    state["chunks_received"] += 1
    events.insert(
        0,
        {
            "type": "stream_chunk_processed",
            "payload": {
                "stream_id": state["stream_id"],
                "chunks_received": state["chunks_received"],
                "points_seen": state["points_seen"],
            },
        },
    )

    result = {"next_state": state, "events": events}
    stream = message.get("stream") or {}
    if stream.get("close") or stream.get("eof"):
        result["complete_job"] = summarize(state)

    print(json.dumps(result))


if __name__ == "__main__":
    main()
