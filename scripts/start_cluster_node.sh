#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
BOX_INDEX=""
COOKIE="${MN_COOKIE:-mirrorneuron}"
REDIS_HOST=""
REDIS_PORT="${MN_REDIS_PORT:-6379}"
REDIS_HA_MODE="${MN_REDIS_HA_MODE:-single}"
REDIS_SENTINELS="${MN_REDIS_SENTINELS:-}"
REDIS_SENTINEL_PORT="${MN_REDIS_SENTINEL_PORT:-26379}"
REDIS_SENTINEL_MASTER="${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}"
REDIS_SENTINEL_QUORUM="${MN_REDIS_SENTINEL_QUORUM:-1}"
REDIS_HA_AUTOCONFIG="${MN_REDIS_HA_AUTOCONFIG:-1}"
REDIS_WAIT_REPLICAS="${MN_REDIS_WAIT_REPLICAS:-0}"
REDIS_WAIT_TIMEOUT_MS="${MN_REDIS_WAIT_TIMEOUT_MS:-100}"
EXECUTOR_CAPACITY="${MN_EXECUTOR_MAX_CONCURRENCY:-2}"
DIST_PORT="${MN_DIST_PORT:-4370}"
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
      --redis-ha-mode <mode>     Redis mode: single or sentinel
      --redis-sentinels <list>   Sentinel peers, defaults to both boxes on 26379
      --sentinel-port <port>     Local Sentinel port, defaults to 26379
      --sentinel-master <name>   Sentinel master name, defaults to mirror-neuron
      --sentinel-quorum <n>      Sentinel quorum, defaults to 1 for dev clusters
      --redis-wait-replicas <n>  WAIT acknowledgements for durable writes
      --skip-redis-ha            Do not auto-configure local Redis/Sentinel
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
    --redis-ha-mode)
      REDIS_HA_MODE="$2"
      shift 2
      ;;
    --redis-sentinels)
      REDIS_SENTINELS="$2"
      shift 2
      ;;
    --sentinel-port)
      REDIS_SENTINEL_PORT="$2"
      shift 2
      ;;
    --sentinel-master)
      REDIS_SENTINEL_MASTER="$2"
      shift 2
      ;;
    --sentinel-quorum)
      REDIS_SENTINEL_QUORUM="$2"
      shift 2
      ;;
    --redis-wait-replicas)
      REDIS_WAIT_REPLICAS="$2"
      shift 2
      ;;
    --skip-redis-ha)
      REDIS_HA_AUTOCONFIG="0"
      shift
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

if [ -z "$REDIS_SENTINELS" ]; then
  REDIS_SENTINELS="${BOX1_IP}:${REDIS_SENTINEL_PORT},${BOX2_IP}:${REDIS_SENTINEL_PORT}"
fi

if [ "$BOX_INDEX" = "1" ]; then
  SELF_NAME="mn1"
  SELF_IP="$BOX1_IP"
else
  SELF_NAME="mn2"
  SELF_IP="$BOX2_IP"
fi

export MN_NODE_NAME="${SELF_NAME}@${SELF_IP}"
export MN_NODE_ROLE="runtime"
export MN_COOKIE="$COOKIE"
export MN_CLUSTER_NODES="mn1@${BOX1_IP},mn2@${BOX2_IP}"
export MN_REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
export MN_REDIS_HA_MODE="$REDIS_HA_MODE"
export MN_REDIS_SENTINELS="$REDIS_SENTINELS"
export MN_REDIS_SENTINEL_MASTER="$REDIS_SENTINEL_MASTER"
export MN_REDIS_SENTINEL_PORT="$REDIS_SENTINEL_PORT"
if [ "$MN_REDIS_HA_MODE" = "sentinel" ] && [ -z "${MN_REDIS_SENTINEL_PASSWORD:-}" ] && [ -n "${MN_REDIS_PASSWORD:-}" ]; then
  export MN_REDIS_SENTINEL_PASSWORD="$MN_REDIS_PASSWORD"
fi
export MN_REDIS_DB="${MN_REDIS_DB:-0}"
export MN_REDIS_WAIT_REPLICAS="$REDIS_WAIT_REPLICAS"
export MN_REDIS_WAIT_TIMEOUT_MS="$REDIS_WAIT_TIMEOUT_MS"
export MN_EXECUTOR_MAX_CONCURRENCY="$EXECUTOR_CAPACITY"
export MN_DIST_PORT="$DIST_PORT"

if [ -z "${ERL_AFLAGS:-}" ]; then
  export ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}"
fi

echo "Starting MirrorNeuron cluster node"
echo "  node: $MN_NODE_NAME"
echo "  cluster: $MN_CLUSTER_NODES"
echo "  redis: $MN_REDIS_URL"
echo "  redis ha: $MN_REDIS_HA_MODE"
if [ "$MN_REDIS_HA_MODE" = "sentinel" ]; then
  echo "  sentinels: $MN_REDIS_SENTINELS"
  echo "  sentinel master: $MN_REDIS_SENTINEL_MASTER"
fi
echo "  executor capacity: $MN_EXECUTOR_MAX_CONCURRENCY"
echo "  dist port: $MN_DIST_PORT"

ensure_openshell_gateway() {
  if openshell status >/dev/null 2>&1 && NO_COLOR=1 openshell sandbox list >/dev/null 2>&1; then
    echo "OpenShell gateway is already healthy; reusing it."
    openshell status
    return
  fi

  echo "OpenShell gateway is unavailable or unhealthy; recreating it..."
  openshell gateway destroy --name openshell >/dev/null 2>&1 || true

  if [ "$RECREATE_OPENSHELL" = "1" ]; then
    echo "Recreating OpenShell gateway..."
    openshell gateway start --recreate
  else
    echo "OpenShell gateway is not healthy; starting it..."
    openshell gateway start
  fi

  if openshell status >/dev/null 2>&1 && NO_COLOR=1 openshell sandbox list >/dev/null 2>&1; then
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

  node: $MN_NODE_NAME
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

if [ "$MN_REDIS_HA_MODE" = "sentinel" ] && [ "$REDIS_HA_AUTOCONFIG" = "1" ]; then
  bash "$ROOT_DIR/scripts/redis_ha.sh" join \
    --self-host "$SELF_IP" \
    --redis-port "$REDIS_PORT" \
    --sentinel-port "$REDIS_SENTINEL_PORT" \
    --sentinels "$REDIS_SENTINELS" \
    --master-name "$REDIS_SENTINEL_MASTER" \
    --quorum "$REDIS_SENTINEL_QUORUM"
fi

exec "$ROOT_DIR/mn" server
