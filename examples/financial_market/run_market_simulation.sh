#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

TRADERS="${TRADERS:-500}"
DURATION_SECONDS="${DURATION_SECONDS:-30}" # Shorten for demo
TICK_SECONDS="${TICK_SECONDS:-1}"
INITIAL_PRICE="${INITIAL_PRICE:-100.0}"
TICK_DELAY_MS="${TICK_DELAY_MS:-0}"
SEED="${SEED:-42}"

echo "Generating financial market simulation bundle..."
BUNDLE_PATH="$(python3 "$SCRIPT_DIR/generate_bundle.py" \
    --traders "$TRADERS" \
    --duration-seconds "$DURATION_SECONDS" \
    --tick-seconds "$TICK_SECONDS" \
    --initial-price "$INITIAL_PRICE" \
    --tick-delay-ms "$TICK_DELAY_MS" \
    --seed "$SEED")"

echo "Bundle generated at: $BUNDLE_PATH"

echo "Validating bundle..."
"$ROOT_DIR/mirror_neuron" validate "$BUNDLE_PATH"

echo "Running financial market simulation in MirrorNeuron runtime..."
RESULT_PATH="$BUNDLE_PATH/result.json"

# Run the simulation and capture the JSON output
"$ROOT_DIR/mirror_neuron" run "$BUNDLE_PATH" --json > "$RESULT_PATH"

echo "Simulation complete! Result written to $RESULT_PATH"

echo "Generating simulation report..."
python3 "$SCRIPT_DIR/summarize_market_result.py" "$RESULT_PATH"

echo "Done!"