#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/examples/divisibility_monitor"
REDIS_URL="${MIRROR_NEURON_REDIS_URL:-redis://127.0.0.1:6379/0}"
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
STARTUP_TIMEOUT_SECONDS="${MIRROR_NEURON_DIVISIBILITY_STARTUP_TIMEOUT_SECONDS:-20}"
HOST_NAME="$(hostname | cut -d. -f1)"
RUN_ID="$(date +%s)-$$"
RUNTIME_SNAME="divisibility-runtime-${RUN_ID}"
CONTROL_SNAME="divisibility-control-${RUN_ID}"
RUNTIME_NODE="${RUNTIME_SNAME}@${HOST_NAME}"
CONTROL_NODE="${CONTROL_SNAME}@${HOST_NAME}"
PID_FILE="/tmp/mirror_neuron_divisibility_runtime_${RUN_ID}.pid"
CONTROL_HELPER="/tmp/mirror_neuron_divisibility_control_${RUN_ID}.sh"

usage() {
  cat <<'EOF'
usage:
  bash examples/divisibility_monitor/run_divisibility_e2e.sh

This script:
  1. starts a detached local runtime node in the background
  2. waits until the runtime is reachable
  3. submits the divisibility monitor job with --no-await
  4. exits while leaving the runtime and job running
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
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
fi

export MIRROR_NEURON_REDIS_URL="$REDIS_URL"

echo "Building CLI..."
(cd "$ROOT_DIR" && mix escript.build >/dev/null)

echo "Validating bundle..."
"$ROOT_DIR/mirror_neuron" validate "$SCRIPT_DIR" >/dev/null

echo "Starting detached runtime node..."
echo "  node: $RUNTIME_NODE"
echo "  mode: detached BEAM"

SystemCmdEPMD() {
  epmd -daemon >/dev/null 2>&1 || true
}

SystemCmdEPMD

env \
  MIRROR_NEURON_REDIS_URL="$REDIS_URL" \
  MIRROR_NEURON_COOKIE="$COOKIE" \
  MIRROR_NEURON_NODE_ROLE="runtime" \
  MIRROR_NEURON_API_ENABLED="false" \
  elixir --erl "-detached" --sname "$RUNTIME_SNAME" --cookie "$COOKIE" \
    -S mix run --no-halt -e 'MirrorNeuron.CLI.Commands.Server.run()'

sleep 1

RUNTIME_PID="$(
  pgrep -fo "beam.smp.*-sname ${RUNTIME_SNAME}( |$)" || true
)"

if [ -z "$RUNTIME_PID" ]; then
  echo "failed to locate detached runtime process for $RUNTIME_NODE" >&2
  exit 1
fi

echo "$RUNTIME_PID" >"$PID_FILE"

cat >"$CONTROL_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
env \\
  MIRROR_NEURON_REDIS_URL="$REDIS_URL" \\
  MIRROR_NEURON_COOKIE="$COOKIE" \\
  MIRROR_NEURON_NODE_ROLE="control" \\
  MIRROR_NEURON_CLUSTER_NODES="$RUNTIME_NODE" \\
  MIRROR_NEURON_API_ENABLED="false" \\
  elixir --sname "$CONTROL_SNAME" --cookie "$COOKIE" \\
    -S mix run -e 'MirrorNeuron.CLI.main(System.argv())' -- "\$@"
EOF
chmod +x "$CONTROL_HELPER"

control_cmd() {
  env \
    MIRROR_NEURON_REDIS_URL="$REDIS_URL" \
    MIRROR_NEURON_COOKIE="$COOKIE" \
    MIRROR_NEURON_NODE_ROLE="control" \
    MIRROR_NEURON_CLUSTER_NODES="$RUNTIME_NODE" \
    MIRROR_NEURON_API_ENABLED="false" \
    elixir --sname "$CONTROL_SNAME" --cookie "$COOKIE" \
      -S mix run -e 'MirrorNeuron.CLI.main(System.argv())' -- "$@"
}

echo "Waiting for runtime node to become reachable..."
deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))

while true; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "timed out waiting for runtime node $RUNTIME_NODE" >&2
    exit 1
  fi

  if ! kill -0 "$RUNTIME_PID" 2>/dev/null; then
    echo "runtime node exited before becoming ready" >&2
    exit 1
  fi

  sleep 2

  set +e
  SUBMIT_JSON="$(control_cmd run "$SCRIPT_DIR" --json --no-await 2>/dev/null)"
  SUBMIT_EXIT=$?
  set -e

  if [ "$SUBMIT_EXIT" -eq 0 ] && printf '%s\n' "$SUBMIT_JSON" | grep -q '"job_id"'; then
    break
  fi
done

echo "Submitting job..."
printf '%s\n' "$SUBMIT_JSON"

JOB_ID="$(
  printf '%s\n' "$SUBMIT_JSON" \
    | python3 -c '
import json, sys
raw = sys.stdin.read()
decoder = json.JSONDecoder()
for index, char in enumerate(raw):
    if char != "{":
        continue
    try:
        payload, _ = decoder.raw_decode(raw[index:])
    except json.JSONDecodeError:
        continue
    if "job_id" in payload:
        print(payload["job_id"])
        break
else:
    raise SystemExit("could not decode submit JSON")
'
)"

echo "Runtime Progress"
echo "  job_id: $JOB_ID"
echo "  runtime_node: $RUNTIME_NODE"
echo "  runtime_pid: $RUNTIME_PID"
echo "  control_helper: $CONTROL_HELPER"
echo
echo "The runtime and job are still running in the background."
echo "Useful follow-up commands:"
echo "  ./mirror_neuron job inspect $JOB_ID"
echo "  ./mirror_neuron job agents $JOB_ID"
echo "  ./mirror_neuron job events $JOB_ID"
echo "  ./mirror_neuron job cancel $JOB_ID"
echo "  $CONTROL_HELPER job cancel $JOB_ID"
echo "  kill \$(cat \"$PID_FILE\")"
