#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/examples/prime_sweep_scale"
WORKERS="1000"
START="1000003"
END=""
CHUNK_SIZE="100"
WAVE_SIZE="25"
WAVE_DELAY_MS="250"
MAX_ATTEMPTS="4"
RETRY_BACKOFF_MS="500"
DRY_RUN="0"
SANDBOX_PREFIX="${MIRROR_NEURON_SCALE_SANDBOX_PREFIX:-prime-worker-}"
SKIP_SANDBOX_CLEANUP="${MIRROR_NEURON_SKIP_BENCHMARK_SANDBOX_CLEANUP:-0}"
CLUSTER_BOX1_IP=""
CLUSTER_BOX2_IP=""
SELF_IP=""

usage() {
  cat <<'EOF'
usage:
  bash examples/prime_sweep_scale/run_scale_test.sh [options]
  bash examples/prime_sweep_scale/run_scale_test.sh [workers] [start] [end] [chunk_size] [wave_size] [wave_delay_ms] [max_attempts] [retry_backoff_ms]

examples:
  bash examples/prime_sweep_scale/run_scale_test.sh --workers 2 --start 1000003 --end 1100007
  bash examples/prime_sweep_scale/run_scale_test.sh -w 1000 -s 1000003 -e 1100007 -c 100 --wave-size 5 --wave-delay-ms 1000 --max-attempts 3 --retry-backoff-ms 1000
  bash examples/prime_sweep_scale/run_scale_test.sh --workers 4 --start 1000003 --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29
  bash examples/prime_sweep_scale/run_scale_test.sh --workers 1000 --start 1000003 --end 1100007 --dry-run

options:
  -w, --workers <n>            Number of logical workers to generate
  -s, --start <n>              Inclusive start of the scanned range
  -e, --end <n>                Optional inclusive upper boundary
  -c, --chunk-size <n>         Numbers assigned to each worker
      --box1-ip <ip>           Use cluster_cli.sh with this box 1 IP
      --box2-ip <ip>           Use cluster_cli.sh with this box 2 IP
      --self-ip <ip>           Use cluster_cli.sh with this machine IP
      --wave-size <n>          Workers released in each launch wave
      --wave-delay-ms <n>      Delay between launch waves in milliseconds
      --max-attempts <n>       Maximum OpenShell attempts per worker
      --retry-backoff-ms <n>   Base retry backoff in milliseconds
      --dry-run                Generate only; do not run
EOF
}

POSITIONAL_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -w|--workers)
      WORKERS="$2"
      shift 2
      ;;
    -s|--start)
      START="$2"
      shift 2
      ;;
    -e|--end)
      END="$2"
      shift 2
      ;;
    -c|--chunk-size)
      CHUNK_SIZE="$2"
      shift 2
      ;;
    --box1-ip)
      CLUSTER_BOX1_IP="$2"
      shift 2
      ;;
    --box2-ip)
      CLUSTER_BOX2_IP="$2"
      shift 2
      ;;
    --self-ip)
      SELF_IP="$2"
      shift 2
      ;;
    --wave-size)
      WAVE_SIZE="$2"
      shift 2
      ;;
    --wave-delay-ms)
      WAVE_DELAY_MS="$2"
      shift 2
      ;;
    --max-attempts)
      MAX_ATTEMPTS="$2"
      shift 2
      ;;
    --retry-backoff-ms)
      RETRY_BACKOFF_MS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ "${#POSITIONAL_ARGS[@]}" -ge 1 ]; then WORKERS="${POSITIONAL_ARGS[0]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 2 ]; then START="${POSITIONAL_ARGS[1]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 3 ]; then END="${POSITIONAL_ARGS[2]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 4 ]; then CHUNK_SIZE="${POSITIONAL_ARGS[3]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 5 ]; then WAVE_SIZE="${POSITIONAL_ARGS[4]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 6 ]; then WAVE_DELAY_MS="${POSITIONAL_ARGS[5]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 7 ]; then MAX_ATTEMPTS="${POSITIONAL_ARGS[6]}"; fi
if [ "${#POSITIONAL_ARGS[@]}" -ge 8 ]; then RETRY_BACKOFF_MS="${POSITIONAL_ARGS[7]}"; fi

RUNNER=("$ROOT_DIR/mirror_neuron")

if [ -n "$CLUSTER_BOX1_IP" ] || [ -n "$CLUSTER_BOX2_IP" ] || [ -n "$SELF_IP" ]; then
  if [ -z "$CLUSTER_BOX1_IP" ] || [ -z "$CLUSTER_BOX2_IP" ] || [ -z "$SELF_IP" ]; then
    echo "cluster mode requires --box1-ip, --box2-ip, and --self-ip together" >&2
    exit 1
  fi

  RUNNER=(
    bash "$ROOT_DIR/scripts/cluster_cli.sh"
    --box1-ip "$CLUSTER_BOX1_IP"
    --box2-ip "$CLUSTER_BOX2_IP"
    --self-ip "$SELF_IP"
    --
  )
fi

cluster_peer_ip() {
  if [ "$SELF_IP" = "$CLUSTER_BOX1_IP" ]; then
    echo "$CLUSTER_BOX2_IP"
  else
    echo "$CLUSTER_BOX1_IP"
  fi
}

cleanup_prime_sandboxes() {
  if [ "$SKIP_SANDBOX_CLEANUP" = "1" ] || ! command -v openshell >/dev/null 2>&1; then
    return
  fi

  sandbox_names="$(
    NO_COLOR=1 openshell sandbox list 2>/dev/null \
      | awk -v prefix="$SANDBOX_PREFIX" 'NR > 1 && index($1, prefix) == 1 { print $1 }'
  )"

  sandbox_count="$(
    printf '%s\n' "$sandbox_names" \
      | sed '/^$/d' \
      | wc -l \
      | tr -d ' '
  )"

  if [ "${sandbox_count}" = "0" ]; then
    return
  fi

  echo "Cleaning up ${sandbox_count} stale benchmark sandboxes with prefix ${SANDBOX_PREFIX}..."
  printf '%s\n' "$sandbox_names" | xargs -n 50 openshell sandbox delete >/dev/null 2>&1 || true
}

if [ "$DRY_RUN" != "1" ]; then
  cleanup_prime_sandboxes
  trap cleanup_prime_sandboxes EXIT
fi

GENERATOR_ARGS=(
  --workers "$WORKERS"
  --start "$START"
  --chunk-size "$CHUNK_SIZE"
  --wave-size "$WAVE_SIZE"
  --wave-delay-ms "$WAVE_DELAY_MS"
  --max-attempts "$MAX_ATTEMPTS"
  --retry-backoff-ms "$RETRY_BACKOFF_MS"
)

if [ -n "$END" ]; then
  GENERATOR_ARGS+=(--end "$END")
fi

if [ -n "$SELF_IP" ]; then
  CLUSTER_OUTPUT_DIR="/tmp/mirror_neuron_cluster_bundles"
  GENERATOR_ARGS+=(--output-dir "$CLUSTER_OUTPUT_DIR")
fi

if [ "$DRY_RUN" = "1" ]; then
  TMP_OUTPUT_DIR="$(mktemp -d /tmp/mirror_neuron_prime_scale.XXXXXX)"
  GENERATOR_ARGS+=(--output-dir "$TMP_OUTPUT_DIR")
fi

BUNDLE_PATH="$(
  python3 "$SCRIPT_DIR/generate_bundle.py" "${GENERATOR_ARGS[@]}"
)"

RESULT_PATH="$BUNDLE_PATH/result.json"
MANIFEST_PATH="$BUNDLE_PATH/manifest.json"

ACTUAL_WORKERS="$(
  python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
workers = [
    node
    for node in manifest["nodes"]
    if node.get("agent_type") == "executor"
]
print(len(workers))
PY
)"

LAST_RANGE_END="$(
  python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
last_end = None

for node in manifest["nodes"]:
    if node.get("agent_type") != "executor":
        continue
    command = node.get("config", {}).get("command", [])
    if len(command) >= 4:
        try:
            last_end = int(command[-1])
        except ValueError:
            pass

print("" if last_end is None else last_end)
PY
)"

echo "Generated bundle:"
echo "  $BUNDLE_PATH"

if [ -n "$SELF_IP" ] && [ "$DRY_RUN" != "1" ]; then
  PEER_IP="$(cluster_peer_ip)"
  echo "Syncing bundle to peer box:"
  echo "  peer=$PEER_IP"
  ssh "$PEER_IP" "mkdir -p \"$(dirname "$BUNDLE_PATH")\" && rm -rf \"$BUNDLE_PATH\""
  scp -r "$BUNDLE_PATH" "${PEER_IP}:$(dirname "$BUNDLE_PATH")/"
fi

if [ -n "$END" ]; then
  echo "Range:"
  echo "  $START - $END"

  if [ -n "$LAST_RANGE_END" ] && [ "$LAST_RANGE_END" -lt "$END" ]; then
    echo "Range coverage warning:"
    echo "  requested workers cover up to $LAST_RANGE_END, not $END"
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run only. Bundle created in /tmp and not executed."
  exit 0
fi

echo "Validating bundle..."
"${RUNNER[@]}" validate "$BUNDLE_PATH" >/dev/null

echo "Running scale test with $ACTUAL_WORKERS workers and chunk size $CHUNK_SIZE..."
echo "Launch waves: $WAVE_SIZE workers every ${WAVE_DELAY_MS}ms; retries: $MAX_ATTEMPTS attempts with ${RETRY_BACKOFF_MS}ms base backoff"
echo "Executor lease cap: default=${MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY:-4} slots per node"
if [ -n "${MIRROR_NEURON_EXECUTOR_POOL_CAPACITIES:-}" ]; then
  echo "Executor pool capacities override: ${MIRROR_NEURON_EXECUTOR_POOL_CAPACITIES}"
fi
if [ "${#RUNNER[@]}" -gt 1 ]; then
  echo "Submitting through cluster CLI:"
  echo "  box1=$CLUSTER_BOX1_IP box2=$CLUSTER_BOX2_IP self=$SELF_IP"
fi
time "${RUNNER[@]}" run "$BUNDLE_PATH" --json >"$RESULT_PATH"

echo "Result written to:"
echo "  $RESULT_PATH"

echo "Summary:"
python3 "$SCRIPT_DIR/summarize_result.py" "$RESULT_PATH"
