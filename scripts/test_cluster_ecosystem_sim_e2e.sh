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
WAIT_TIMEOUT_SECONDS="${MIRROR_NEURON_SIM_WAIT_TIMEOUT_SECONDS:-420}"
POLL_INTERVAL_SECONDS="5"
ANIMALS="2000"
REGIONS="16"
DURATION_SECONDS="300"
TICK_SECONDS="5"
REMOTE_PATH_PREFIX='export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH";'
LOCAL_LOG="/tmp/mirror_neuron_mn1_ecosim.log"
REMOTE_LOG="/tmp/mirror_neuron_mn2_ecosim.log"
BUNDLE_ROOT="/tmp/mirror_neuron_cluster_bundles"

usage() {
  cat <<'EOF'
usage:
  bash scripts/test_cluster_ecosystem_sim_e2e.sh --box1-ip <ip> --box2-ip <ip> [options]

example:
  bash scripts/test_cluster_ecosystem_sim_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35

options:
      --box1-ip <ip>             IP of box 1
      --box2-ip <ip>             IP of box 2
      --animals <n>              Total animals, defaults to 2000
      --regions <n>              Number of region agents, defaults to 16
      --duration-seconds <n>     Simulated duration, defaults to 300
      --tick-seconds <n>         Simulated seconds per tick, defaults to 5
      --remote-root <path>       MirrorNeuron checkout on box 2
      --cookie <cookie>          Erlang cookie, defaults to mirrorneuron
      --dist-port <port>         Erlang distribution port, defaults to 4370
      --wait-timeout-seconds <n> Maximum time to wait, defaults to 420
      --poll-interval-seconds <n>
                                 Progress poll interval while waiting, defaults to 5
      --skip-sync                Do not rsync the repo to box 2 first
      --keep-cluster-up          Leave both runtime nodes running after the test
  -h, --help                     Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --box1-ip) BOX1_IP="$2"; shift 2 ;;
    --box2-ip) BOX2_IP="$2"; shift 2 ;;
    --animals) ANIMALS="$2"; shift 2 ;;
    --regions) REGIONS="$2"; shift 2 ;;
    --duration-seconds) DURATION_SECONDS="$2"; shift 2 ;;
    --tick-seconds) TICK_SECONDS="$2"; shift 2 ;;
    --remote-root) REMOTE_ROOT="$2"; shift 2 ;;
    --cookie) COOKIE="$2"; shift 2 ;;
    --dist-port) DIST_PORT="$2"; shift 2 ;;
    --wait-timeout-seconds) WAIT_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --poll-interval-seconds) POLL_INTERVAL_SECONDS="$2"; shift 2 ;;
    --skip-sync) SKIP_SYNC="1"; shift ;;
    --keep-cluster-up) KEEP_CLUSTER_UP="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$BOX1_IP" ] || [ -z "$BOX2_IP" ]; then
  usage >&2
  exit 1
fi

local_runtime_pids() { pgrep -f 'mn.*server' || true; }
remote_runtime_pids() { ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX pgrep -f 'mn.*server' || true"; }

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

build_local() {
  echo "Building box 1 runtime..."
  (cd "$ROOT_DIR" && mix escript.build >/dev/null)
}

build_remote() {
  echo "Building box 2 runtime..."
  ssh "$BOX2_IP" "cd \"$REMOTE_ROOT\" && $REMOTE_PATH_PREFIX mix escript.build >/dev/null"
}

start_local_runtime() {
  echo "Starting box 1 runtime..."
  (
    cd "$ROOT_DIR"
    export ERL_AFLAGS="-kernel inet_dist_listen_min $DIST_PORT inet_dist_listen_max $DIST_PORT"
    export MIRROR_NEURON_NODE_NAME="mn1@$BOX1_IP"
    export MIRROR_NEURON_NODE_ROLE="runtime"
    export MIRROR_NEURON_COOKIE="$COOKIE"
    export MIRROR_NEURON_CLUSTER_NODES="mn1@$BOX1_IP,mn2@$BOX2_IP"
    export MIRROR_NEURON_REDIS_URL="redis://$BOX1_IP:6379/0"
    ./mn server >"$LOCAL_LOG" 2>&1 &
    echo $!
  )
}

start_remote_runtime() {
  echo "Starting box 2 runtime..."
  ssh "$BOX2_IP" "cd \"$REMOTE_ROOT\" && $REMOTE_PATH_PREFIX export ERL_AFLAGS='-kernel inet_dist_listen_min $DIST_PORT inet_dist_listen_max $DIST_PORT'; export MIRROR_NEURON_NODE_NAME='mn2@$BOX2_IP'; export MIRROR_NEURON_NODE_ROLE='runtime'; export MIRROR_NEURON_COOKIE='$COOKIE'; export MIRROR_NEURON_CLUSTER_NODES='mn1@$BOX1_IP,mn2@$BOX2_IP'; export MIRROR_NEURON_REDIS_URL='redis://$BOX1_IP:6379/0'; nohup ./mn server >'$REMOTE_LOG' 2>&1 </dev/null & echo \$!"
}

cluster_inspect_nodes() {
  bash "$ROOT_DIR/scripts/cluster_cli.sh" \
    --box1-ip "$BOX1_IP" \
    --box2-ip "$BOX2_IP" \
    --self-ip "$BOX1_IP" \
    -- inspect nodes
}

wait_for_cluster() {
  echo "Waiting for both runtime nodes to join..."
  local attempt
  for attempt in $(seq 1 40); do
    local nodes
    nodes="$(cluster_inspect_nodes 2>/dev/null || true)"
    if printf '%s\n' "$nodes" | grep -q "mn1@$BOX1_IP" && printf '%s\n' "$nodes" | grep -q "mn2@$BOX2_IP"; then
      echo "Cluster is healthy."
      return 0
    fi
    sleep 2
  done

  echo "Cluster failed to form." >&2
  echo "Box 1 log:" >&2
  tail -n 40 "$LOCAL_LOG" >&2 || true
  echo "Box 2 log:" >&2
  ssh "$BOX2_IP" "tail -n 40 '$REMOTE_LOG'" >&2 || true
  return 1
}

force_cluster_connect() {
  echo "Forcing runtime nodes to connect..."

  local deadline now
  deadline=$((SECONDS + 20))

  while true; do
    if ERL_AFLAGS='-kernel inet_dist_listen_min 4374 inet_dist_listen_max 4374' \
      elixir --name "bootstrap_${$}@${BOX1_IP}" --cookie "$COOKIE" -e "
        mn1 = :\"mn1@${BOX1_IP}\"
        mn2 = :\"mn2@${BOX2_IP}\"
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

cleanup() {
  if [ "$KEEP_CLUSTER_UP" = "1" ]; then
    return
  fi

  echo "Cleaning up runtimes..."
  stop_runtime_local
  stop_runtime_remote
}

trap cleanup EXIT

sync_remote_repo
build_local
build_remote
stop_runtime_local
stop_runtime_remote
epmd -daemon
ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX epmd -daemon" >/dev/null 2>&1 || true
LOCAL_PID="$(start_local_runtime)"
echo "$LOCAL_PID"
REMOTE_PID="$(start_remote_runtime)"
echo "$REMOTE_PID"
force_cluster_connect
wait_for_cluster

echo "Running cluster ecosystem simulation..."
bash "$ROOT_DIR/examples/ecosystem_simulation/run_simulation_e2e.sh" \
  --animals "$ANIMALS" \
  --regions "$REGIONS" \
  --duration-seconds "$DURATION_SECONDS" \
  --tick-seconds "$TICK_SECONDS" \
  --box1-ip "$BOX1_IP" \
  --box2-ip "$BOX2_IP" \
  --self-ip "$BOX1_IP" \
  --wait-timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
  --poll-interval-seconds "$POLL_INTERVAL_SECONDS"
