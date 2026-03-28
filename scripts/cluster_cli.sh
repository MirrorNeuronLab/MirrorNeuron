#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
SELF_IP=""
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
REDIS_HOST=""
REDIS_PORT="${MIRROR_NEURON_REDIS_PORT:-6379}"
CLI_PORT="${MIRROR_NEURON_CLI_DIST_PORT:-4371}"

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
      --redis-host <host>      Redis host, defaults to box1 IP
      --redis-port <port>      Redis port, defaults to 6379
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
  echo "missing mirror_neuron command after --" >&2
  usage >&2
  exit 1
fi

prompt_if_missing BOX1_IP "Box 1 IP: "
prompt_if_missing BOX2_IP "Box 2 IP: "
prompt_if_missing SELF_IP "This machine IP: "

if [ -z "$REDIS_HOST" ]; then
  REDIS_HOST="$BOX1_IP"
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

export ERL_AFLAGS="-kernel inet_dist_listen_min ${CLI_PORT} inet_dist_listen_max ${CLI_PORT}"
export MIRROR_NEURON_NODE_NAME="cli-$(date +%s)-$$@${SELF_IP}"
export MIRROR_NEURON_NODE_ROLE="control"
export MIRROR_NEURON_COOKIE="$COOKIE"
export MIRROR_NEURON_CLUSTER_NODES="mn1@${BOX1_IP},mn2@${BOX2_IP}"
export MIRROR_NEURON_REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"

echo "Running MirrorNeuron cluster CLI"
echo "  node: $MIRROR_NEURON_NODE_NAME"
echo "  cluster: $MIRROR_NEURON_CLUSTER_NODES"
echo "  redis: $MIRROR_NEURON_REDIS_URL"
echo "  cli dist port: $CLI_PORT"

exec "$ROOT_DIR/mirror_neuron" "$@"
