#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOB_PATH="$ROOT_DIR/examples/openshell_worker_demo"
DRY_RUN="0"
JSON_OUTPUT="1"

usage() {
  cat <<EOF
usage:
  bash demo/openshell_pipeline/run_demo.sh [options]

examples:
  bash demo/openshell_pipeline/run_demo.sh
  bash demo/openshell_pipeline/run_demo.sh --job-path "$ROOT_DIR/examples/openshell_worker_demo"
  bash demo/openshell_pipeline/run_demo.sh --dry-run

options:
  -j, --job-path <path>   Job bundle to validate/run
      --dry-run           Validate inputs only; do not run
      --no-json           Run without --json output
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -j|--job-path)
      JOB_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --no-json)
      JSON_OUTPUT="0"
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

echo "Job bundle:"
echo "  $JOB_PATH"

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run only. Bundle was not executed."
  exit 0
fi

echo "Validating bundle..."
"$ROOT_DIR/mirror_neuron" validate "$JOB_PATH" >/dev/null

echo "Running sandboxed demo..."
if [ "$JSON_OUTPUT" = "1" ]; then
  "$ROOT_DIR/mirror_neuron" run "$JOB_PATH" --json
else
  "$ROOT_DIR/mirror_neuron" run "$JOB_PATH"
fi
