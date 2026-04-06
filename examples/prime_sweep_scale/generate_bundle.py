#!/usr/bin/env python3
import argparse
import json
import shutil
from pathlib import Path


def build_chunks(start: int, workers: int, chunk_size: int, end: int | None = None) -> list[tuple[int, int]]:
    chunks: list[tuple[int, int]] = []

    for index in range(workers):
        range_start = start + index * chunk_size

        if end is not None and range_start > end:
            break

        range_end = start + (index + 1) * chunk_size - 1

        if end is not None:
            range_end = min(range_end, end)

        chunks.append((range_start, range_end))

    return chunks


def build_manifest(
    workers: int,
    start: int,
    chunk_size: int,
    end: int | None,
    wave_size: int,
    wave_delay_ms: int,
    max_attempts: int,
    retry_backoff_ms: int,
) -> dict:
    chunks = build_chunks(start, workers, chunk_size, end)
    actual_workers = len(chunks)

    if actual_workers == 0:
        raise ValueError("no work generated for the requested range")

    nodes = [
        {
            "node_id": "dispatcher",
            "agent_type": "router",
            "type": "map",
            "role": "root_coordinator",
            "config": {"emit_type": "prime_chunk_request"},
        },
        {
            "node_id": "collector",
            "agent_type": "aggregator",
            "type": "reduce",
            "config": {
                "complete_after": actual_workers,
                "output_message_type": "prime_chunk_collection",
            },
        },
        {
            "node_id": "summarizer",
            "agent_type": "executor",
            "type": "reduce",
            "config": {
                "name_prefix": "prime-summary",
                "upload_path": "summary_worker",
                "upload_as": "summary_worker",
                "workdir": "/sandbox/job/summary_worker",
                "runner_module": "MirrorNeuron.Runner.HostLocal",
                "command": ["python3", "scripts/summarize_prime_sweep.py"],
                "output_message_type": None,
            },
        },
    ]

    edges = []

    for index, (range_start, range_end) in enumerate(chunks, start=1):
        worker_id = f"prime_worker_{index:04d}"
        startup_delay_ms = ((index - 1) // wave_size) * wave_delay_ms

        nodes.append(
            {
                "node_id": worker_id,
                "agent_type": "executor",
                "type": "map",
                "config": {
                    "name_prefix": worker_id.replace("_", "-"),
                    "from": "base",
                    "upload_path": "prime_worker",
                    "upload_as": "prime_worker",
                    "workdir": "/sandbox/job/prime_worker",
                    "command": [
                        "python3",
                        "scripts/check_prime_range.py",
                        worker_id,
                        str(range_start),
                        str(range_end),
                    ],
                    "pool": "default",
                    "pool_slots": 1,
                    "output_message_type": "prime_chunk_result",
                    "startup_delay_ms": startup_delay_ms,
                    "max_attempts": max_attempts,
                    "retry_backoff_ms": retry_backoff_ms,
                    "no_keep": True,
                    "no_auto_providers": True,
                    "tty": False,
                },
            }
        )

        edges.append(
            {
                "edge_id": f"dispatch_{worker_id}",
                "from_node": "dispatcher",
                "to_node": worker_id,
                "message_type": "prime_chunk_request",
            }
        )
        edges.append(
            {
                "edge_id": f"{worker_id}_to_aggregator",
                "from_node": worker_id,
                "to_node": "collector",
                "message_type": "prime_chunk_result",
            }
        )

    edges.append(
        {
            "edge_id": "collector_to_summarizer",
            "from_node": "collector",
            "to_node": "summarizer",
            "message_type": "prime_chunk_collection",
        }
    )

    return {
        "manifest_version": "1.0",
        "graph_id": f"prime_sweep_{actual_workers}_workers",
        "job_name": f"prime-sweep-{actual_workers}-workers",
        "entrypoints": ["dispatcher"],
        "initial_inputs": {
            "dispatcher": [
                {
                    "benchmark": "prime_sweep",
                    "worker_count": actual_workers,
                    "requested_workers": workers,
                    "chunk_size": chunk_size,
                    "range_start": chunks[0][0],
                    "range_end": chunks[-1][1],
                }
            ]
        },
        "nodes": nodes,
        "edges": edges,
        "policies": {"recovery_mode": "cluster_recover"},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a large-scale prime sweep job bundle.")
    parser.add_argument("--workers", type=int, default=1000, help="Number of sandbox workers to generate")
    parser.add_argument("--start", type=int, default=1_000_003, help="Starting number for range generation")
    parser.add_argument("--end", type=int, default=None, help="Optional inclusive upper boundary for range generation")
    parser.add_argument("--chunk-size", type=int, default=100, help="Numbers assigned to each worker")
    parser.add_argument(
        "--wave-size",
        type=int,
        default=25,
        help="How many workers to release in each launch wave",
    )
    parser.add_argument(
        "--wave-delay-ms",
        type=int,
        default=250,
        help="Delay between worker launch waves in milliseconds",
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        default=4,
        help="Maximum OpenShell attempts per worker for transient failures",
    )
    parser.add_argument(
        "--retry-backoff-ms",
        type=int,
        default=500,
        help="Base retry backoff in milliseconds for transient sandbox failures",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "generated",
        help="Directory to write generated bundles into",
    )
    args = parser.parse_args()

    if args.end is not None and args.end < args.start:
        raise SystemExit("--end must be greater than or equal to --start")

    effective_workers = args.workers

    script_dir = Path(__file__).resolve().parent
    template_payloads = script_dir / "payloads"

    preview_chunks = build_chunks(args.start, effective_workers, args.chunk_size, args.end)

    if not preview_chunks:
        raise SystemExit("requested worker/range combination generated no work")

    actual_workers = len(preview_chunks)

    range_suffix = f"_to_{args.end}" if args.end is not None else ""
    bundle_dir = args.output_dir / (
        f"prime_sweep_{actual_workers}_workers_from_{args.start}{range_suffix}_chunk_{args.chunk_size}"
    )
    payloads_dir = bundle_dir / "payloads"

    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)

    payloads_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(template_payloads, payloads_dir, dirs_exist_ok=True)

    manifest = build_manifest(
        effective_workers,
        args.start,
        args.chunk_size,
        args.end,
        max(args.wave_size, 1),
        max(args.wave_delay_ms, 0),
        max(args.max_attempts, 1),
        max(args.retry_backoff_ms, 0),
    )
    (bundle_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    print(bundle_dir)


if __name__ == "__main__":
    main()
