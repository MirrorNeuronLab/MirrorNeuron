#!/usr/bin/env python3
import argparse
import json
import shutil
from pathlib import Path


def build_manifest(args: argparse.Namespace) -> dict:
    python_bin = str(args.python_bin)

    nodes = [
        {
            "node_id": "ingress",
            "agent_type": "router",
            "type": "map",
            "role": "root_coordinator",
            "config": {"emit_type": "simulation_start"},
        },
        {
            "node_id": "collector",
            "agent_type": "aggregator",
            "type": "reduce",
            "config": {
                "complete_after": 1,
                "output_message_type": "shared_world_collection",
            },
        },
        {
            "node_id": "visualizer",
            "agent_type": "executor",
            "type": "reduce",
            "config": {
                "name_prefix": "mpe-crowd-visualizer",
                "runner_module": "MirrorNeuron.Runner.HostLocal",
                "upload_path": "visualizer",
                "upload_as": "visualizer",
                "workdir": "/sandbox/job/visualizer",
                "command": [python_bin, "scripts/build_shared_world_visualization.py"],
                "output_message_type": None,
                "pass_env": ["PATH"],
                "tty": False,
            },
        },
        {
            "node_id": "shared_world",
            "agent_type": "executor",
            "type": "map",
            "role": "world",
            "config": {
                "name_prefix": "mpe-crowd-world",
                "runner_module": "MirrorNeuron.Runner.HostLocal",
                "upload_path": "world_worker",
                "upload_as": "world_worker",
                "workdir": "/sandbox/job/world_worker",
                "command": [python_bin, "scripts/run_shared_world.py"],
                "output_message_type": "shared_world_result",
                "pass_env": ["PATH"],
                "tty": False,
                "environment": {
                    "SIMULATION_SEED": str(args.seed),
                    "MAX_CYCLES": str(args.max_cycles),
                    "NUM_GOOD": str(args.good_agents),
                    "NUM_ADVERSARIES": str(args.adversaries),
                    "NUM_OBSTACLES": str(args.obstacles),
                    "POLICY_MODE": args.policy_mode,
                },
            },
        },
    ]

    edges = [
        {
            "edge_id": "ingress_to_world",
            "from_node": "ingress",
            "to_node": "shared_world",
            "message_type": "simulation_start",
        },
        {
            "edge_id": "world_to_collector",
            "from_node": "shared_world",
            "to_node": "collector",
            "message_type": "shared_world_result",
        },
        {
            "edge_id": "collector_to_visualizer",
            "from_node": "collector",
            "to_node": "visualizer",
            "message_type": "shared_world_collection",
        },
    ]

    total_agents = args.good_agents + args.adversaries

    return {
        "manifest_version": "1.0",
        "graph_id": "mpe_shared_world_visualization_v2",
        "job_name": "mpe-shared-world-visualization",
        "entrypoints": ["ingress"],
        "initial_inputs": {
            "ingress": [
                {
                    "scenario": "pettingzoo_simple_tag_shared_world",
                    "good_agents": args.good_agents,
                    "adversaries": args.adversaries,
                    "total_agents": total_agents,
                    "obstacles": args.obstacles,
                    "max_cycles": args.max_cycles,
                    "seed": args.seed,
                    "policy_mode": args.policy_mode,
                    "description": (
                        "Run one shared MPE world with many coexisting agents that collide, "
                        "chase, flee, and crowd around obstacles."
                    ),
                }
            ]
        },
        "nodes": nodes,
        "edges": edges,
        "policies": {"recovery_mode": "cluster_recover"},
    }


def bundle_name(args: argparse.Namespace) -> str:
    total_agents = args.good_agents + args.adversaries
    return f"mpe_shared_world_{total_agents}_agents_{args.max_cycles}_cycles"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a MirrorNeuron bundle for one shared PettingZoo MPE world."
    )
    parser.add_argument("--good-agents", type=int, default=25)
    parser.add_argument("--adversaries", type=int, default=75)
    parser.add_argument("--obstacles", type=int, default=8)
    parser.add_argument("--max-cycles", type=int, default=60)
    parser.add_argument("--seed", type=int, default=4_200)
    parser.add_argument("--policy-mode", choices=["swarm", "random"], default="swarm")
    parser.add_argument("--python-bin", type=Path, default=Path("python3"))
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "generated",
    )
    args = parser.parse_args()

    args.good_agents = max(args.good_agents, 1)
    args.adversaries = max(args.adversaries, 1)
    args.obstacles = max(args.obstacles, 1)
    args.max_cycles = max(args.max_cycles, 5)

    root = Path(__file__).resolve().parent
    bundle_dir = args.output_dir / bundle_name(args)

    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)

    bundle_dir.mkdir(parents=True, exist_ok=True)
    payloads_dir = bundle_dir / "payloads"
    payloads_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / "payloads", payloads_dir, dirs_exist_ok=True)

    manifest = build_manifest(args)
    (bundle_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(bundle_dir)


if __name__ == "__main__":
    main()
