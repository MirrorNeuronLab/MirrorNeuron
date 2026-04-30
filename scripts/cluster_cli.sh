#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
SELF_IP=""
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
REDIS_HOST=""
REDIS_PORT="${MIRROR_NEURON_REDIS_PORT:-6379}"
REDIS_HA_MODE="${MIRROR_NEURON_REDIS_HA_MODE:-single}"
REDIS_SENTINELS="${MIRROR_NEURON_REDIS_SENTINELS:-}"
REDIS_SENTINEL_PORT="${MIRROR_NEURON_REDIS_SENTINEL_PORT:-26379}"
REDIS_SENTINEL_MASTER="${MIRROR_NEURON_REDIS_SENTINEL_MASTER:-mirror-neuron}"
REDIS_WAIT_REPLICAS="${MIRROR_NEURON_REDIS_WAIT_REPLICAS:-0}"
REDIS_WAIT_TIMEOUT_MS="${MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS:-100}"
CLI_PORT="${MIRROR_NEURON_CLI_DIST_PORT:-4371}"
SEED_IP=""

usage() {
  cat <<EOF
usage:
  bash scripts/cluster_cli.sh [options] -- <mirror_neuron args...>

examples:
  bash scripts/cluster_cli.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29 -- inspect nodes
  bash scripts/cluster_cli.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29 -- run examples/research_flow

options:
      --box1-ip <ip>           IP of box 1
      --box2-ip <ip>           IP of box 2
      --self-ip <ip>           IP of this machine for the temporary CLI node
      --seed-ip <ip>           Runtime node IP to use as the control-plane seed, defaults to self IP
      --redis-host <host>      Redis host, defaults to box1 IP
      --redis-port <port>      Redis port, defaults to 6379
      --redis-ha-mode <mode>   Redis mode: single or sentinel
      --redis-sentinels <list> Sentinel peers, defaults to both boxes on 26379
      --sentinel-port <port>   Local Sentinel port, defaults to 26379
      --sentinel-master <name> Sentinel master name, defaults to mirror-neuron
      --cookie <cookie>        Erlang cookie, defaults to mirrorneuron
      --cli-port <port>        Temporary CLI Erlang distribution port, defaults to 4371
  -h, --help                   Show this help
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
    --self-ip)
      SELF_IP="$2"
      shift 2
      ;;
    --seed-ip)
      SEED_IP="$2"
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
    --cookie)
      COOKIE="$2"
      shift 2
      ;;
    --cli-port)
      CLI_PORT="$2"
      shift 2
      ;;
    --)
      shift
      break
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

if [ "$#" -eq 0 ]; then
  echo "missing mn command after --" >&2
  usage >&2
  exit 1
fi

prompt_if_missing BOX1_IP "Box 1 IP: "
prompt_if_missing BOX2_IP "Box 2 IP: "
prompt_if_missing SELF_IP "This machine IP: "

if [ -z "$REDIS_HOST" ]; then
  REDIS_HOST="$BOX1_IP"
fi

if [ -z "$REDIS_SENTINELS" ]; then
  REDIS_SENTINELS="${BOX1_IP}:${REDIS_SENTINEL_PORT},${BOX2_IP}:${REDIS_SENTINEL_PORT}"
fi

if [ -z "$SEED_IP" ]; then
  SEED_IP="$SELF_IP"
fi

if [ "$SEED_IP" = "$BOX1_IP" ]; then
  SEED_NODE="mn1@${BOX1_IP}"
elif [ "$SEED_IP" = "$BOX2_IP" ]; then
  SEED_NODE="mn2@${BOX2_IP}"
else
  echo "--seed-ip must match either --box1-ip or --box2-ip" >&2
  exit 1
fi

epmd -daemon

find_free_port() {
  local port="$1"

  while nc -z 127.0.0.1 "$port" >/dev/null 2>&1; do
    port=$((port + 1))
  done

  echo "$port"
}

CLI_PORT="$(find_free_port "$CLI_PORT")"

export ERL_AFLAGS="-connect_all false -kernel inet_dist_listen_min ${CLI_PORT} inet_dist_listen_max ${CLI_PORT}"
export MIRROR_NEURON_NODE_NAME="cli-$(date +%s)-$$@${SELF_IP}"
export MIRROR_NEURON_NODE_ROLE="control"
export MIRROR_NEURON_COOKIE="$COOKIE"
export MIRROR_NEURON_CLUSTER_NODES="$SEED_NODE"
export MIRROR_NEURON_REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
export MIRROR_NEURON_REDIS_HA_MODE="$REDIS_HA_MODE"
export MIRROR_NEURON_REDIS_SENTINELS="$REDIS_SENTINELS"
export MIRROR_NEURON_REDIS_SENTINEL_MASTER="$REDIS_SENTINEL_MASTER"
export MIRROR_NEURON_REDIS_SENTINEL_PORT="$REDIS_SENTINEL_PORT"
export MIRROR_NEURON_REDIS_DB="${MIRROR_NEURON_REDIS_DB:-0}"
export MIRROR_NEURON_REDIS_WAIT_REPLICAS="$REDIS_WAIT_REPLICAS"
export MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS="$REDIS_WAIT_TIMEOUT_MS"

export MIRROR_NEURON_API_PORT="$(find_free_port 4010)"

>&2 echo "Running MirrorNeuron cluster CLI"
>&2 echo "  node: $MIRROR_NEURON_NODE_NAME"
>&2 echo "  seed: $MIRROR_NEURON_CLUSTER_NODES"
>&2 echo "  redis: $MIRROR_NEURON_REDIS_URL"
>&2 echo "  redis ha: $MIRROR_NEURON_REDIS_HA_MODE"
if [ "$MIRROR_NEURON_REDIS_HA_MODE" = "sentinel" ]; then
  >&2 echo "  sentinels: $MIRROR_NEURON_REDIS_SENTINELS"
fi
>&2 echo "  cli dist port: $CLI_PORT"
>&2 echo "  cli api port: $MIRROR_NEURON_API_PORT"

exec "$ROOT_DIR/mn" "$@"
