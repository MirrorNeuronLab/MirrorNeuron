#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
DIST_PORT="${MIRROR_NEURON_DIST_PORT:-4370}"
REMOTE_ROOT="${MIRROR_NEURON_REMOTE_ROOT:-/Users/homer/Personal_Projects/MirrorNeuron}"
SKIP_SYNC="0"
KEEP_CLUSTER_UP="0"
WAIT_TIMEOUT_SECONDS="${MIRROR_NEURON_STREAM_WAIT_TIMEOUT_SECONDS:-120}"
POLL_INTERVAL_SECONDS="3"
SAMPLE_COUNT="60"
CHUNK_SIZE="6"
BASELINE="24"
JITTER="4"
PEAK_HEIGHT="55"
PEAK_POSITIONS=""
CONTENT_ENCODING="gzip"
REMOTE_PATH_PREFIX='export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH";'
LOCAL_LOG="/tmp/mirror_neuron_mn1_stream_e2e.log"
REMOTE_LOG="/tmp/mirror_neuron_mn2_stream_e2e.log"
BUNDLE_ROOT="/tmp/mirror_neuron_cluster_bundles"

usage() {
  cat <<'EOF'
usage:
  bash scripts/test_cluster_streaming_e2e.sh --box1-ip <ip> --box2-ip <ip> [options]

example:
  bash scripts/test_cluster_streaming_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35

options:
      --box1-ip <ip>             IP of box 1
      --box2-ip <ip>             IP of box 2
      --sample-count <n>         Number of telemetry samples, defaults to 60
      --chunk-size <n>           Samples per stream chunk, defaults to 6
      --baseline <n>             Baseline value, defaults to 24
      --jitter <n>               Baseline jitter, defaults to 4
      --peak-height <n>          Added value for anomaly spikes, defaults to 55
      --peak-positions <list>    Comma-separated 1-based peak positions
      --content-encoding <enc>   gzip or identity, defaults to gzip
      --remote-root <path>       MirrorNeuron checkout on box 2
      --cookie <cookie>          Erlang cookie, defaults to mirrorneuron
      --dist-port <port>         Erlang distribution port, defaults to 4370
      --wait-timeout-seconds <n> Maximum time to wait for job completion
      --poll-interval-seconds <n>
                                 Progress poll interval while waiting, defaults to 3
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
    --sample-count)
      SAMPLE_COUNT="$2"
      shift 2
      ;;
    --chunk-size)
      CHUNK_SIZE="$2"
      shift 2
      ;;
    --baseline)
      BASELINE="$2"
      shift 2
      ;;
    --jitter)
      JITTER="$2"
      shift 2
      ;;
    --peak-height)
      PEAK_HEIGHT="$2"
      shift 2
      ;;
    --peak-positions)
      PEAK_POSITIONS="$2"
      shift 2
      ;;
    --content-encoding)
      CONTENT_ENCODING="$2"
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
      MIRROR_NEURON_NODE_NAME="mn1@${BOX1_IP}" \
      MIRROR_NEURON_NODE_ROLE="runtime" \
      MIRROR_NEURON_COOKIE="$COOKIE" \
      MIRROR_NEURON_CLUSTER_NODES="mn1@${BOX1_IP},mn2@${BOX2_IP}" \
      MIRROR_NEURON_REDIS_URL="redis://${BOX1_IP}:6379/0" \
      MIRROR_NEURON_DIST_PORT="$DIST_PORT" \
      ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}" \
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
      MIRROR_NEURON_NODE_NAME=\"mn2@${BOX2_IP}\" \
      MIRROR_NEURON_NODE_ROLE=\"runtime\" \
      MIRROR_NEURON_COOKIE=\"$COOKIE\" \
      MIRROR_NEURON_CLUSTER_NODES=\"mn1@${BOX1_IP},mn2@${BOX2_IP}\" \
      MIRROR_NEURON_REDIS_URL=\"redis://${BOX1_IP}:6379/0\" \
      MIRROR_NEURON_DIST_PORT=\"$DIST_PORT\" \
      ERL_AFLAGS=\"-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}\" \
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
    if ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
      ERL_AFLAGS='-kernel inet_dist_listen_min 4373 inet_dist_listen_max 4373' \
      elixir --name 'bootstrap_${$}@${BOX2_IP}' --cookie '$COOKIE' -e '
        mn1 = :\"mn1@${BOX1_IP}\"
        mn2 = :\"mn2@${BOX2_IP}\"
        Node.connect(mn1)
        Node.connect(mn2)
        :rpc.call(mn1, Node, :connect, [mn2])
        :timer.sleep(500)
        ok =
          case :rpc.call(mn1, Node, :list, []) do
            nodes when is_list(nodes) -> mn2 in nodes
            _ -> false
          end
        System.halt(if(ok, do: 0, else: 1))
      ' >/dev/null 2>&1"; then
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
        --box1-ip "$BOX1_IP" \
        --box2-ip "$BOX2_IP" \
        --self-ip "$BOX1_IP" \
        -- inspect nodes 2>/dev/null || true
    )"

    if printf '%s\n' "$output" | grep -q "mn1@${BOX1_IP}" \
      && printf '%s\n' "$output" | grep -q "mn2@${BOX2_IP}"; then
      echo "Cluster is healthy."
      return
    fi

    now=$SECONDS
    if [ "$now" -ge "$deadline" ]; then
      echo "Timed out waiting for cluster formation." >&2
      echo "Local cluster view:" >&2
      bash "$ROOT_DIR/scripts/cluster_cli.sh" \
        --box1-ip "$BOX1_IP" \
        --box2-ip "$BOX2_IP" \
        --self-ip "$BOX1_IP" \
        -- inspect nodes >&2 || true
      echo "Remote cluster view:" >&2
      ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX cd \"$REMOTE_ROOT\" && bash scripts/cluster_cli.sh --box1-ip \"$BOX1_IP\" --box2-ip \"$BOX2_IP\" --self-ip \"$BOX2_IP\" -- inspect nodes" >&2 || true
      echo "Box 1 log:" >&2
      tail -n 50 "$LOCAL_LOG" >&2 || true
      echo "Box 2 log:" >&2
      ssh "$BOX2_IP" "tail -n 50 \"$REMOTE_LOG\"" >&2 || true
      exit 1
    fi

    sleep 1
  done
}

cleanup_all() {
  if [ "$KEEP_CLUSTER_UP" = "1" ]; then
    return
  fi

  echo "Cleaning up runtimes..."
  stop_runtime_local
  stop_runtime_remote
}

trap cleanup_all EXIT

stop_runtime_local
stop_runtime_remote
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

echo "Running cluster streaming smoke test..."
RUN_ARGS=(
  --sample-count "$SAMPLE_COUNT"
  --chunk-size "$CHUNK_SIZE"
  --baseline "$BASELINE"
  --jitter "$JITTER"
  --peak-height "$PEAK_HEIGHT"
  --content-encoding "$CONTENT_ENCODING"
  --wait-timeout-seconds "$WAIT_TIMEOUT_SECONDS"
  --poll-interval-seconds "$POLL_INTERVAL_SECONDS"
  --box1-ip "$BOX1_IP"
  --box2-ip "$BOX2_IP"
  --self-ip "$BOX1_IP"
  --output-dir "$BUNDLE_ROOT"
)

if [ -n "$PEAK_POSITIONS" ]; then
  RUN_ARGS+=(--peak-positions "$PEAK_POSITIONS")
fi

bash "$ROOT_DIR/examples/streaming_peak_demo/run_streaming_e2e.sh" "${RUN_ARGS[@]}"
