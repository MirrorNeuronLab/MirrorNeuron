#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Verify the monitor runs
echo "Validating bundle..."
"$ROOT_DIR/mirror_neuron" validate "$SCRIPT_DIR"

echo "Starting slack monitor in MirrorNeuron runtime..."
echo "Press Ctrl+C to stop."

# Run the monitor continuously
"$ROOT_DIR/mirror_neuron" run "$SCRIPT_DIR"
