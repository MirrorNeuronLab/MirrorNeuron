#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/examples/mpe_simple_push_visualization"
GOOD_AGENTS="25"
ADVERSARIES="75"
OBSTACLES="8"
MAX_CYCLES="60"
SEED="4200"
POLICY_MODE="swarm"
DRY_RUN="0"
OPEN_RESULT="0"
OUTPUT_DIR=""
REDIS_URL="${MIRROR_NEURON_REDIS_URL:-redis://127.0.0.1:6379/0}"
PYTHON_VERSION="${MIRROR_NEURON_SIMPLE_PUSH_PYTHON_VERSION:-3.12}"
VENV_DIR="${MIRROR_NEURON_SIMPLE_PUSH_VENV_DIR:-$SCRIPT_DIR/.venv}"
VENV_PYTHON=""

usage() {
  cat <<'EOF'
usage:
  bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh [options]

examples:
  bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh
  bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh --good-agents 20 --adversaries 80
  bash examples/mpe_simple_push_visualization/run_simple_push_e2e.sh --max-cycles 90 --open

options:
      --good-agents <n>      Number of good agents, defaults to 25
      --adversaries <n>      Number of adversaries, defaults to 75
      --obstacles <n>        Number of obstacles, defaults to 8
      --max-cycles <n>       PettingZoo max_cycles, defaults to 60
      --seed <n>             Simulation seed, defaults to 4200
      --policy-mode <mode>   swarm or random, defaults to swarm
      --output-dir <path>    Override generator output directory
      --open                 Open the generated HTML visualization on success
      --dry-run              Generate only; do not validate or run
  -h, --help                Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --good-agents)
      GOOD_AGENTS="$2"
      shift 2
      ;;
    --adversaries)
      ADVERSARIES="$2"
      shift 2
      ;;
    --obstacles)
      OBSTACLES="$2"
      shift 2
      ;;
    --max-cycles)
      MAX_CYCLES="$2"
      shift 2
      ;;
    --seed)
      SEED="$2"
      shift 2
      ;;
    --policy-mode)
      POLICY_MODE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --open)
      OPEN_RESULT="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

ensure_python_env() {
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required for this example because it provisions a Python ${PYTHON_VERSION} environment." >&2
    exit 1
  fi

  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "Creating example venv with Python ${PYTHON_VERSION}..."
    uv venv --python "$PYTHON_VERSION" "$VENV_DIR" >/dev/null
    "$VENV_DIR/bin/python" -m ensurepip --upgrade >/dev/null
  fi

  VENV_PYTHON="$VENV_DIR/bin/python"

  if ! "$VENV_PYTHON" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("pettingzoo") else 1)
PY
  then
    echo "Installing PettingZoo MPE dependencies into $VENV_DIR..."
    "$VENV_PYTHON" -m pip install -q 'pettingzoo[mpe]'
  fi

  export PATH="$VENV_DIR/bin:$PATH"
}

ensure_python_env
export MIRROR_NEURON_REDIS_URL="$REDIS_URL"

BUNDLE_ARGS=(
  --good-agents "$GOOD_AGENTS"
  --adversaries "$ADVERSARIES"
  --obstacles "$OBSTACLES"
  --max-cycles "$MAX_CYCLES"
  --seed "$SEED"
  --policy-mode "$POLICY_MODE"
  --python-bin "$VENV_PYTHON"
)

if [ "$DRY_RUN" = "1" ]; then
  TMP_OUTPUT_DIR="$(mktemp -d /tmp/mirror_neuron_mpe_shared_world.XXXXXX)"
  OUTPUT_DIR="$TMP_OUTPUT_DIR"
fi

if [ -n "$OUTPUT_DIR" ]; then
  BUNDLE_ARGS+=(--output-dir "$OUTPUT_DIR")
fi

BUNDLE_PATH="$("$VENV_PYTHON" "$SCRIPT_DIR/generate_bundle.py" "${BUNDLE_ARGS[@]}")"
RESULT_PATH="$BUNDLE_PATH/result.json"
TOTAL_AGENTS=$((GOOD_AGENTS + ADVERSARIES))

echo "Generated bundle:"
echo "  $BUNDLE_PATH"

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run only. Bundle path:"
  echo "  $BUNDLE_PATH"
  exit 0
fi

echo "Building CLI..."
(cd "$ROOT_DIR" && mix escript.build >/dev/null)

echo "Validating bundle..."
"$ROOT_DIR/mirror_neuron" validate "$BUNDLE_PATH" >/dev/null

echo "Running shared-world MPE visualization job..."
echo "  total agents: $TOTAL_AGENTS"
echo "  good agents: $GOOD_AGENTS"
echo "  adversaries: $ADVERSARIES"
echo "  obstacles: $OBSTACLES"
echo "  max cycles: $MAX_CYCLES"
echo "  redis url: $MIRROR_NEURON_REDIS_URL"

"$ROOT_DIR/mirror_neuron" run "$BUNDLE_PATH" --json | tee "$RESULT_PATH"

echo "Writing HTML visualization..."
SUMMARY_OUTPUT="$("$VENV_PYTHON" "$SCRIPT_DIR/summarize_result.py" "$RESULT_PATH")"
printf '%s\n' "$SUMMARY_OUTPUT"

HTML_PATH="$(
  "$VENV_PYTHON" - "$RESULT_PATH" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1]).parent / "mpe_crowd_visualization.html"
print(path)
PY
)"

if [ "$OPEN_RESULT" = "1" ] && command -v open >/dev/null 2>&1; then
  open "$HTML_PATH"
fi
