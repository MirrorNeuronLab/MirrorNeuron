#!/usr/bin/env python3
import json
import os
from pathlib import Path


def load_input() -> dict:
    input_path = Path(os.environ["MIRROR_NEURON_INPUT_FILE"])
    return json.loads(input_path.read_text())


def summarize(messages: list[dict]) -> dict:
    chunk_results = []

    for payload in messages:
        chunk = json.loads(payload["sandbox"]["stdout"])
        chunk_results.append(
            {
                "agent_id": payload["agent_id"],
                "worker_id": chunk["worker_id"],
                "range_start": chunk["range_start"],
                "range_end": chunk["range_end"],
                "checked_numbers": chunk["checked_numbers"],
                "prime_count": chunk["prime_count"],
                "primes": chunk["primes"],
            }
        )

    primes = sorted([prime for chunk in chunk_results for prime in chunk["primes"]])
    checked_numbers = sum(chunk["checked_numbers"] for chunk in chunk_results)
    sorted_chunks = sorted(chunk_results, key=lambda chunk: chunk["range_start"])

    return {
        "mode": "prime_sweep",
        "worker_count": len(chunk_results),
        "checked_numbers": checked_numbers,
        "prime_count": len(primes),
        "range_start": sorted_chunks[0]["range_start"],
        "range_end": sorted_chunks[-1]["range_end"],
        "first_25_primes": primes[:25],
        "last_25_primes": primes[-25:],
        "chunks": [
            {
                key: value
                for key, value in chunk.items()
                if key != "primes"
            }
            for chunk in sorted_chunks
        ],
    }


def main() -> None:
    incoming = load_input()
    messages = incoming.get("messages", [])

    print(json.dumps({"complete_job": summarize(messages)}))


if __name__ == "__main__":
    main()
