#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
BOX1_NODE_IP=""
BOX2_NODE_IP=""
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
DIST_PORT="${MIRROR_NEURON_DIST_PORT:-4370}"
EXECUTOR_CAPACITY="${MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY:-2}"
REMOTE_ROOT="${MIRROR_NEURON_REMOTE_ROOT:-/Users/homer/Personal_Projects/MirrorNeuron}"
SKIP_SYNC="0"
KEEP_CLUSTER_UP="0"
WAIT_TIMEOUT_SECONDS="${MIRROR_NEURON_LLM_WAIT_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="5"
MODEL="${MIRROR_NEURON_GEMINI_MODEL:-gemini-2.5-flash-lite}"
REMOTE_PATH_PREFIX='export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH";'
LOCAL_LOG="/tmp/mirror_neuron_mn1_llm_e2e.log"
REMOTE_LOG="/tmp/mirror_neuron_mn2_llm_e2e.log"
BUNDLE_ROOT="/tmp/mirror_neuron_cluster_bundles"

usage() {
  cat <<'EOF'
usage:
  bash scripts/test_cluster_llm_codegen_e2e.sh --box1-ip <ip> --box2-ip <ip> [options]

example:
  bash scripts/test_cluster_llm_codegen_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35

options:
      --box1-ip <ip>             IP of box 1
      --box2-ip <ip>             IP of box 2
      --model <name>             Gemini model, defaults to gemini-2.5-flash-lite
      --remote-root <path>       MirrorNeuron checkout on box 2
      --cookie <cookie>          Erlang cookie, defaults to mirrorneuron
      --dist-port <port>         Erlang distribution port, defaults to 4370
      --executor-capacity <n>    Executor lease cap per node, defaults to 2
      --wait-timeout-seconds <n> Maximum time to wait for job completion
      --poll-interval-seconds <n>
                                 Progress poll interval while waiting, defaults to 5
      --skip-sync                Do not rsync the repo to box 2 first
      --keep-cluster-up          Leave both runtime nodes running after the test
  -h, --help                     Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --box1-ip)
      BOX1_IP="$2"
      shift 2
      ;;
    --box2-ip)
      BOX2_IP="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --remote-root)
      REMOTE_ROOT="$2"
      shift 2
      ;;
    --cookie)
      COOKIE="$2"
      shift 2
      ;;
    --dist-port)
      DIST_PORT="$2"
      shift 2
      ;;
    --executor-capacity)
      EXECUTOR_CAPACITY="$2"
      shift 2
      ;;
    --wait-timeout-seconds)
      WAIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --poll-interval-seconds)
      POLL_INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --skip-sync)
      SKIP_SYNC="1"
      shift
      ;;
    --keep-cluster-up)
      KEEP_CLUSTER_UP="1"
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

if [ -z "$BOX1_IP" ] || [ -z "$BOX2_IP" ]; then
  usage >&2
  exit 1
fi

if [ -z "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ]; then
  echo "GEMINI_API_KEY or GOOGLE_API_KEY must be set before running this e2e test." >&2
  exit 1
fi

quote_env_value() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

detect_local_ip() {
  local peer_ip="${1:-8.8.8.8}"

  python3 - "$peer_ip" <<'PY'
import socket
import sys

peer_ip = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect((peer_ip, 80))
    print(s.getsockname()[0])
finally:
    s.close()
PY
}

detect_remote_ip() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
    python3 - <<'PY'
import socket
import subprocess

for interface in ('en0', 'en1'):
    try:
        result = subprocess.run(
            ['ipconfig', 'getifaddr', interface],
            capture_output=True,
            text=True,
            check=False,
        )
        value = result.stdout.strip()
        if value:
            print(value)
            raise SystemExit(0)
    except FileNotFoundError:
        break

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
finally:
    s.close()
PY
  "
}

BOX1_NODE_IP="$(detect_local_ip "$BOX2_IP")"
BOX2_NODE_IP="$(detect_remote_ip)"

if [ "$BOX1_NODE_IP" != "$BOX1_IP" ] || [ "$BOX2_NODE_IP" != "$BOX2_IP" ]; then
  echo "Detected runtime node IPs:"
  echo "  box1 runtime ip: $BOX1_NODE_IP (ssh target was $BOX1_IP)"
  echo "  box2 runtime ip: $BOX2_NODE_IP (ssh target was $BOX2_IP)"
fi

LOCAL_GEMINI_KEY="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
LOCAL_GEMINI_KEY_QUOTED="$(quote_env_value "$LOCAL_GEMINI_KEY")"

local_runtime_pids() {
  pgrep -f 'mn.*server' || true
}

remote_runtime_pids() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX pgrep -f 'mn.*server' || true"
}

stop_runtime_local() {
  local pids
  pids="$(local_runtime_pids || true)"
  if [ -n "$pids" ]; then
    echo "Stopping local MirrorNeuron runtimes: $pids"
    kill $pids >/dev/null 2>&1 || true
    sleep 1
  fi
}

stop_runtime_remote() {
  local pids
  pids="$(remote_runtime_pids || true)"
  if [ -n "$pids" ]; then
    echo "Stopping box 2 MirrorNeuron runtimes: $pids"
    ssh "$BOX2_IP" "kill $pids >/dev/null 2>&1 || true"
    sleep 1
  fi
}

cleanup_sandboxes_local() {
  if ! command -v openshell >/dev/null 2>&1; then
    return
  fi

  local names
  names="$(
    NO_COLOR=1 openshell sandbox list 2>/dev/null \
      | awk 'NR > 1 && index($1, "mirror-neuron-job-") == 1 {print $1}'
  )"

  if [ -n "$names" ]; then
    echo "Deleting local LLM test sandboxes..."
    printf '%s\n' "$names" | xargs -n 20 openshell sandbox delete >/dev/null 2>&1 || true
  fi
}

cleanup_sandboxes_remote() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
    if command -v openshell >/dev/null 2>&1; then
      names=\$(
        NO_COLOR=1 openshell sandbox list 2>/dev/null \
          | awk 'NR > 1 && index(\$1, \"mirror-neuron-job-\") == 1 {print \$1}'
      )
      if [ -n \"\$names\" ]; then
        printf \"%s\n\" \"\$names\" | xargs -n 20 openshell sandbox delete >/dev/null 2>&1 || true
      fi
    fi
  "
}

ensure_local_docker() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  if command -v open >/dev/null 2>&1; then
    echo "Starting Docker Desktop on box 1..."
    open -a Docker >/dev/null 2>&1 || true
  fi

  local attempt
  for attempt in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  echo "Docker is not ready on box 1. Verify Docker Desktop is running." >&2
  return 1
}

ensure_remote_docker() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
    if docker info >/dev/null 2>&1; then
      exit 0
    fi

    if command -v open >/dev/null 2>&1; then
      echo \"Starting Docker Desktop on box 2...\"
      open -a Docker >/dev/null 2>&1 || true
    fi

    for attempt in \$(seq 1 60); do
      if docker info >/dev/null 2>&1; then
        exit 0
      fi
      sleep 2
    done

    echo \"Docker is not ready on box 2. Verify Docker Desktop is running.\" >&2
    exit 1
  "
}

ensure_local_gateway() {
  if openshell status >/dev/null 2>&1 && NO_COLOR=1 openshell sandbox list >/dev/null 2>&1; then
    return
  fi

  openshell gateway destroy --name openshell >/dev/null 2>&1 || true

  openshell gateway start >/dev/null

  if ! NO_COLOR=1 openshell sandbox list >/dev/null 2>&1; then
    echo "OpenShell gateway on box 1 is not usable after restart." >&2
    return 1
  fi
}

ensure_remote_gateway() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
    if openshell status >/dev/null 2>&1 && NO_COLOR=1 openshell sandbox list >/dev/null 2>&1; then
      exit 0
    fi

    openshell gateway destroy --name openshell >/dev/null 2>&1 || true

    openshell gateway start >/dev/null

    NO_COLOR=1 openshell sandbox list >/dev/null 2>&1
  "
}

build_local() {
  echo "Building box 1 runtime..."
  (cd "$ROOT_DIR" && mix escript.build >/dev/null)
}

sync_remote_repo() {
  if [ "$SKIP_SYNC" = "1" ]; then
    return
  fi
  echo "Syncing repo to box 2..."
  ssh "$BOX2_IP" "mkdir -p \"$REMOTE_ROOT\""
  rsync -az --delete \
    --exclude '.git/' \
    --exclude '_build/' \
    --exclude 'deps/' \
    --exclude 'var/' \
    "$ROOT_DIR/" "$BOX2_IP:$REMOTE_ROOT/"
}

build_remote() {
  echo "Building box 2 runtime..."
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX cd \"$REMOTE_ROOT\" && mix escript.build >/dev/null"
}

start_local_runtime() {
  echo "Starting box 1 runtime..."
  : >"$LOCAL_LOG"
  (
    cd "$ROOT_DIR"
    epmd -daemon
    env \
      MIRROR_NEURON_NODE_NAME="mn1@${BOX1_NODE_IP}" \
      MIRROR_NEURON_NODE_ROLE="runtime" \
      MIRROR_NEURON_COOKIE="$COOKIE" \
      MIRROR_NEURON_CLUSTER_NODES="mn1@${BOX1_NODE_IP},mn2@${BOX2_NODE_IP}" \
      MIRROR_NEURON_REDIS_URL="redis://${BOX1_NODE_IP}:6379/0" \
      MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY="$EXECUTOR_CAPACITY" \
      MIRROR_NEURON_DIST_PORT="$DIST_PORT" \
      ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}" \
      GEMINI_API_KEY="$LOCAL_GEMINI_KEY" \
      MIRROR_NEURON_LOG_PATH="$LOCAL_LOG" \
      python3 - <<'PY'
import os
import subprocess

log_path = os.environ["MIRROR_NEURON_LOG_PATH"]
with open(log_path, "ab", buffering=0) as log_file:
    proc = subprocess.Popen(
        ["./mn", "server"],
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=os.environ.copy(),
    )
print(proc.pid)
PY
  )
}

start_remote_runtime() {
  echo "Starting box 2 runtime..."
  ssh "$BOX2_IP" "
    set -euo pipefail
    $REMOTE_PATH_PREFIX
    cd \"$REMOTE_ROOT\"
    epmd -daemon
    : >\"$REMOTE_LOG\"
    env \
      MIRROR_NEURON_NODE_NAME=\"mn2@${BOX2_NODE_IP}\" \
      MIRROR_NEURON_NODE_ROLE=\"runtime\" \
      MIRROR_NEURON_COOKIE=\"$COOKIE\" \
      MIRROR_NEURON_CLUSTER_NODES=\"mn1@${BOX1_NODE_IP},mn2@${BOX2_NODE_IP}\" \
      MIRROR_NEURON_REDIS_URL=\"redis://${BOX1_NODE_IP}:6379/0\" \
      MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY=\"$EXECUTOR_CAPACITY\" \
      MIRROR_NEURON_DIST_PORT=\"$DIST_PORT\" \
      ERL_AFLAGS=\"-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}\" \
      GEMINI_API_KEY=${LOCAL_GEMINI_KEY_QUOTED} \
      MIRROR_NEURON_LOG_PATH=\"$REMOTE_LOG\" \
      python3 - <<'PY'
import os
import subprocess

log_path = os.environ[\"MIRROR_NEURON_LOG_PATH\"]
with open(log_path, \"ab\", buffering=0) as log_file:
    proc = subprocess.Popen(
        [\"./mn\", \"server\"],
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=os.environ.copy(),
    )
print(proc.pid)
PY
  "
}

force_cluster_connect() {
  echo "Forcing runtime nodes to connect..."
  local deadline now
  deadline=$((SECONDS + 20))

  while true; do
    if ERL_AFLAGS='-kernel inet_dist_listen_min 4373 inet_dist_listen_max 4373' \
      elixir --name "bootstrap_${$}@${BOX1_NODE_IP}" --cookie "$COOKIE" -e "
        mn1 = :\"mn1@${BOX1_NODE_IP}\"
        mn2 = :\"mn2@${BOX2_NODE_IP}\"
        Node.connect(mn2)
        :rpc.call(mn1, Node, :connect, [mn2])
        :timer.sleep(500)
        ok =
          case :rpc.call(mn1, Node, :list, []) do
            nodes when is_list(nodes) -> mn2 in nodes
            _ -> false
          end
        System.halt(if(ok, do: 0, else: 1))
      " >/dev/null 2>&1; then
      return
    fi
    now=$SECONDS
    if [ "$now" -ge "$deadline" ]; then
      echo "Could not establish runtime-to-runtime connection." >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_cluster() {
  echo "Waiting for both runtime nodes to join..."
  local deadline now output
  deadline=$((SECONDS + 30))

  while true; do
    output="$(
      bash "$ROOT_DIR/scripts/cluster_cli.sh" \
        --box1-ip "$BOX1_NODE_IP" \
        --box2-ip "$BOX2_NODE_IP" \
        --self-ip "$BOX1_NODE_IP" \
        -- inspect nodes 2>/dev/null || true
    )"

    if printf '%s\n' "$output" | grep -q "mn1@${BOX1_NODE_IP}" \
      && printf '%s\n' "$output" | grep -q "mn2@${BOX2_NODE_IP}"; then
      echo "Cluster is healthy."
      return
    fi

    now=$SECONDS
    if [ "$now" -ge "$deadline" ]; then
      echo "Timed out waiting for cluster formation." >&2
      exit 1
    fi
    sleep 1
  done
}

cleanup_all() {
  if [ "$KEEP_CLUSTER_UP" = "1" ]; then
    return
  fi

  echo "Cleaning up runtimes and test sandboxes..."
  stop_runtime_local
  stop_runtime_remote
  cleanup_sandboxes_local
  cleanup_sandboxes_remote
}

trap cleanup_all EXIT

stop_runtime_local
stop_runtime_remote
cleanup_sandboxes_local
cleanup_sandboxes_remote
ensure_local_docker
ensure_remote_docker
ensure_local_gateway
ensure_remote_gateway
sync_remote_repo
build_local
build_remote
start_local_runtime
start_remote_runtime
force_cluster_connect
wait_for_cluster

echo "Running cluster LLM codegen/review test..."
BUNDLE_PATH="$(
  python3 "$ROOT_DIR/examples/llm_codegen_review/generate_bundle.py" \
    --model "$MODEL" \
    --output-dir "$BUNDLE_ROOT"
)"
RESULT_PATH="$BUNDLE_PATH/result.json"

echo "Generated bundle:"
echo "  $BUNDLE_PATH"
echo "Syncing bundle to peer box:"
echo "  peer=$BOX2_IP"
ssh "$BOX2_IP" "mkdir -p \"$(dirname "$BUNDLE_PATH")\" && rm -rf \"$BUNDLE_PATH\""
scp -r "$BUNDLE_PATH" "${BOX2_IP}:$(dirname "$BUNDLE_PATH")/" >/dev/null

echo "Validating bundle..."
bash "$ROOT_DIR/scripts/cluster_cli.sh" \
  --box1-ip "$BOX1_NODE_IP" \
  --box2-ip "$BOX2_NODE_IP" \
  --self-ip "$BOX1_NODE_IP" \
  -- validate "$BUNDLE_PATH" >/dev/null

echo "Submitting LLM job through cluster CLI..."
echo "Running awaited cluster job..."
time bash "$ROOT_DIR/scripts/cluster_cli.sh" \
  --box1-ip "$BOX1_NODE_IP" \
  --box2-ip "$BOX2_NODE_IP" \
  --self-ip "$BOX1_NODE_IP" \
  -- run "$BUNDLE_PATH" --json | tee "$RESULT_PATH"

JOB_ID="$(
  python3 - "$RESULT_PATH" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text()
decoder = json.JSONDecoder()

for index, char in enumerate(raw):
    if char != "{":
        continue
    try:
        payload, _ = decoder.raw_decode(raw[index:])
        print(payload["job_id"])
        break
    except json.JSONDecodeError:
        continue
else:
    raise SystemExit("could not decode cluster result JSON")
PY
)"

echo "Result written to:"
echo "  $RESULT_PATH"
echo "Summary:"
python3 "$ROOT_DIR/examples/llm_codegen_review/summarize_result.py" "$RESULT_PATH"

echo "Worker placement by node:"
(
  cd "$ROOT_DIR"
  env \
    MIRROR_NEURON_REDIS_URL="redis://${BOX1_NODE_IP}:6379/0" \
    mix run --no-start -e '
      Application.ensure_all_started(:mirror_neuron)
      job_id = System.argv() |> List.first()

      case MirrorNeuron.inspect_agents(job_id) do
        {:ok, agents} ->
          agents
          |> Enum.filter(&(&1["agent_type"] == "executor"))
          |> Enum.group_by(& &1["assigned_node"])
          |> Enum.sort_by(fn {node, _agents} -> node end)
          |> Enum.each(fn {node, node_agents} ->
            IO.puts("  #{node}: #{length(node_agents)} executor(s)")
          end)

        {:error, reason} ->
          IO.puts(:stderr, "Could not inspect agent placement: #{inspect(reason)}")
          System.halt(1)
      end
    ' -- "$JOB_ID"
)

echo "End-to-end cluster LLM test completed."
