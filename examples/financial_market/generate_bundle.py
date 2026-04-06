#!/usr/bin/env python3
import argparse
import json
import secrets
import shutil
import random
from pathlib import Path


def build_manifest(args: argparse.Namespace) -> dict:
    total_traders = args.traders

    shared_config = {
        "duration_seconds": args.duration_seconds,
        "tick_seconds": args.tick_seconds,
        "initial_price": args.initial_price,
        "tick_delay_ms": args.tick_delay_ms,
    }

    nodes = [
        {
            "node_id": "ingress",
            "agent_type": "router",
            "type": "map",
            "role": "root_coordinator",
            "config": {"emit_type": "simulation_start"},
        },
        {
            "node_id": "exchange",
            "agent_type": "module",
            "type": "reduce",
            "role": "exchange",
            "config": {
                **shared_config,
                "module": "MirrorNeuron.Examples.FinancialMarket.ExchangeAgent",
                "module_source": "beam_modules/exchange_agent.ex",
            },
        },
        {
            "node_id": "collector",
            "agent_type": "aggregator",
            "type": "reduce",
            "config": {
                "complete_after": total_traders + 1,  # traders + exchange
                "output_message_type": "market_collection",
            },
        },
        {
            "node_id": "summarizer",
            "agent_type": "module",
            "type": "reduce",
            "role": "summarizer",
            "config": {
                "module": "MirrorNeuron.Examples.FinancialMarket.SummarizerAgent",
                "module_source": "beam_modules/summarizer_agent.ex",
            },
        },
    ]

    edges = [
        {
            "edge_id": "ingress_to_exchange",
            "from_node": "ingress",
            "to_node": "exchange",
            "message_type": "simulation_start",
        },
        {
            "edge_id": "collector_to_summarizer",
            "from_node": "collector",
            "to_node": "summarizer",
            "message_type": "market_collection",
        },
        {
            "edge_id": "exchange_to_collector",
            "from_node": "exchange",
            "to_node": "collector",
            "message_type": "exchange_summary",
        },
    ]

    # Deterministic strategy allocation
    rand = random.Random(args.seed)
    strategies = ["momentum", "mean_reversion", "noise", "market_maker"]
    weights = [0.15, 0.15, 0.6, 0.1]

    for i in range(total_traders):
        agent_id = f"trader_{i:03d}"
        strategy = rand.choices(strategies, weights=weights)[0]

        nodes.append(
            {
                "node_id": agent_id,
                "agent_type": "module",
                "type": "reduce",
                "role": strategy,
                "config": {
                    **shared_config,
                    "strategy": strategy,
                    "module": "MirrorNeuron.Examples.FinancialMarket.TraderAgent",
                    "module_source": "beam_modules/trader_agent.ex",
                },
            }
        )

        # Exchange to trader (for data)
        edges.append(
            {
                "edge_id": f"exchange_to_{agent_id}_data",
                "from_node": "exchange",
                "to_node": agent_id,
                "message_type": "market_data",
            }
        )

        # Trader to exchange (for orders)
        edges.append(
            {
                "edge_id": f"{agent_id}_to_exchange",
                "from_node": agent_id,
                "to_node": "exchange",
                "message_type": "place_order",
            }
        )

        # Trader to collector
        edges.append(
            {
                "edge_id": f"{agent_id}_to_collector",
                "from_node": agent_id,
                "to_node": "collector",
                "message_type": "trader_summary",
            }
        )

    return {
        "manifest_version": "1.0",
        "graph_id": "financial_market_simulation_v1",
        "job_name": "financial-market-simulation",
        "entrypoints": ["ingress"],
        "initial_inputs": {
            "ingress": [
                {
                    "scenario": "market_dynamics_test",
                    "duration_seconds": args.duration_seconds,
                    "tick_seconds": args.tick_seconds,
                    "seed": args.seed,
                }
            ]
        },
        "nodes": nodes,
        "edges": edges,
        "policies": {"recovery_mode": "cluster_recover"},
    }


def bundle_name(args: argparse.Namespace) -> str:
    return f"financial_market_{args.traders}traders_{args.duration_seconds}s"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate the financial market simulation bundle."
    )
    parser.add_argument("--traders", type=int, default=500)
    parser.add_argument("--duration-seconds", type=int, default=60)
    parser.add_argument("--tick-seconds", type=int, default=1)
    parser.add_argument("--initial-price", type=float, default=100.0)
    parser.add_argument("--tick-delay-ms", type=int, default=10)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "generated",
    )
    args = parser.parse_args()

    if args.seed is None:
        args.seed = secrets.randbelow(1_000_000_000)

    root = Path(__file__).resolve().parent
    bundle_dir = args.output_dir / bundle_name(args)

    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)

    bundle_dir.mkdir(parents=True, exist_ok=True)
    payloads_dir = bundle_dir / "payloads"
    payloads_dir.mkdir(parents=True, exist_ok=True)
    beam_modules_src = root / "payloads" / "beam_modules"
    beam_modules_dest = payloads_dir / "beam_modules"
    shutil.copytree(beam_modules_src, beam_modules_dest)

    manifest = build_manifest(args)
    (bundle_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(bundle_dir)


if __name__ == "__main__":
    main()
