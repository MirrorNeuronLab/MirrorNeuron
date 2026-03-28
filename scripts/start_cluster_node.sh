#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
BOX_INDEX=""
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
REDIS_HOST=""
REDIS_PORT="${MIRROR_NEURON_REDIS_PORT:-6379}"
EXECUTOR_CAPACITY="${MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY:-2}"
DIST_PORT="${MIRROR_NEURON_DIST_PORT:-4370}"
START_OPENSHELL="1"
RECREATE_OPENSHELL="0"
RESTART_RUNTIME="0"

usage() {
  cat <<EOF
usage:
  bash scripts/start_cluster_node.sh [options]

examples:
  bash scripts/start_cluster_node.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --box 1
  bash scripts/start_cluster_node.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --box 2 --redis-host 192.168.4.29

options:
      --box1-ip <ip>             IP of box 1
      --box2-ip <ip>             IP of box 2
      --box <1|2>                Which box this machine is
      --redis-host <host>        Redis host, defaults to box1 IP
      --redis-port <port>        Redis port, defaults to 6379
      --cookie <cookie>          Erlang cookie, defaults to mirrorneuron
      --executor-capacity <n>    Local executor lease capacity, defaults to 2
      --dist-port <port>         Erlang distribution port, defaults to 4370
      --skip-openshell           Do not start openshell gateway automatically
      --recreate-openshell       Force destroy/recreate of the openshell gateway
      --restart-runtime          Stop an existing local MirrorNeuron runtime on this port before starting
  -h, --help                     Show this help
EOF
}

prompt_if_missing() {
  local var_name="$1"
  local prompt_text="$2"

  if [ -z "${!var_name}" ]; then
    read -r -p "$prompt_text" "$var_name"
  fi
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
    --box)
      BOX_INDEX="$2"
      shift 2
      ;;
    --redis-host)
      REDIS_HOST="$2"
      shift 2
      ;;
    --redis-port)
      REDIS_PORT="$2"
      shift 2
      ;;
    --cookie)
      COOKIE="$2"
      shift 2
      ;;
    --executor-capacity)
      EXECUTOR_CAPACITY="$2"
      shift 2
      ;;
    --dist-port)
      DIST_PORT="$2"
      shift 2
      ;;
    --skip-openshell)
      START_OPENSHELL="0"
      shift
      ;;
    --recreate-openshell)
      RECREATE_OPENSHELL="1"
      shift
      ;;
    --restart-runtime)
      RESTART_RUNTIME="1"
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

prompt_if_missing BOX1_IP "Box 1 IP: "
prompt_if_missing BOX2_IP "Box 2 IP: "
prompt_if_missing BOX_INDEX "This machine is box (1 or 2): "

if [ "$BOX_INDEX" != "1" ] && [ "$BOX_INDEX" != "2" ]; then
  echo "--box must be 1 or 2" >&2
  exit 1
fi

if [ -z "$REDIS_HOST" ]; then
  REDIS_HOST="$BOX1_IP"
fi

if [ "$BOX_INDEX" = "1" ]; then
  SELF_NAME="mn1"
  SELF_IP="$BOX1_IP"
else
  SELF_NAME="mn2"
  SELF_IP="$BOX2_IP"
fi

export MIRROR_NEURON_NODE_NAME="${SELF_NAME}@${SELF_IP}"
export MIRROR_NEURON_NODE_ROLE="runtime"
export MIRROR_NEURON_COOKIE="$COOKIE"
export MIRROR_NEURON_CLUSTER_NODES="mn1@${BOX1_IP},mn2@${BOX2_IP}"
export MIRROR_NEURON_REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
export MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY="$EXECUTOR_CAPACITY"
export MIRROR_NEURON_DIST_PORT="$DIST_PORT"

if [ -z "${ERL_AFLAGS:-}" ]; then
  export ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}"
fi

echo "Starting MirrorNeuron cluster node"
echo "  node: $MIRROR_NEURON_NODE_NAME"
echo "  cluster: $MIRROR_NEURON_CLUSTER_NODES"
echo "  redis: $MIRROR_NEURON_REDIS_URL"
echo "  executor capacity: $MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY"
echo "  dist port: $MIRROR_NEURON_DIST_PORT"

ensure_openshell_gateway() {
  if openshell status >/dev/null 2>&1; then
    echo "OpenShell gateway is already healthy; reusing it."
    openshell status
    return
  fi

  if [ "$RECREATE_OPENSHELL" = "1" ]; then
    echo "Recreating OpenShell gateway..."
    openshell gateway start --recreate
    openshell status
    return
  fi

  echo "OpenShell gateway is not healthy; starting it..."

  if openshell gateway start; then
    openshell status
    return
  fi

  cat >&2 <<EOF
OpenShell gateway start failed.

Try one of these:
  1. Retry this script with --recreate-openshell
  2. Start the runtime without touching OpenShell:
     bash scripts/start_cluster_node.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --box $BOX_INDEX --skip-openshell
  3. Manually reset OpenShell:
     openshell gateway destroy --name openshell
     openshell gateway start
     openshell status
EOF
  exit 1
}

ensure_epmd() {
  if epmd -names >/dev/null 2>&1; then
    return
  fi

  echo "Starting epmd for Erlang distribution..."
  epmd -daemon

  if ! epmd -names >/dev/null 2>&1; then
    cat >&2 <<EOF
Failed to start epmd locally.

Check whether another service is blocking the Erlang port mapper on this machine.
EOF
    exit 1
  fi
}

existing_runtime_pid() {
  lsof -nP -iTCP:"$DIST_PORT" -sTCP:LISTEN 2>/dev/null \
    | awk '/beam\.smp/ {print $2; exit}'
}

handle_existing_runtime() {
  local existing_pid
  existing_pid="$(existing_runtime_pid)"

  if [ -z "$existing_pid" ]; then
    return
  fi

  if [ "$RESTART_RUNTIME" = "1" ]; then
    echo "Stopping existing MirrorNeuron runtime on port $DIST_PORT (pid $existing_pid)..."
    kill "$existing_pid"
    sleep 1
    return
  fi

  cat <<EOF
MirrorNeuron runtime already appears to be running locally.

  node: $MIRROR_NEURON_NODE_NAME
  port: $DIST_PORT
  pid:  $existing_pid

If you want to keep using that node, leave it running and open a new terminal for:
  bash scripts/cluster_cli.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --self-ip $SELF_IP -- inspect nodes

If you want to replace it, rerun with:
  bash scripts/start_cluster_node.sh --box1-ip $BOX1_IP --box2-ip $BOX2_IP --box $BOX_INDEX --restart-runtime
EOF
  exit 0
}

if [ "$START_OPENSHELL" = "1" ]; then
  ensure_openshell_gateway
fi

ensure_epmd
handle_existing_runtime

exec "$ROOT_DIR/mirror_neuron" server
