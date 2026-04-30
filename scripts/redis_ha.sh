#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi

if [ "$COMMAND" = "-h" ] || [ "$COMMAND" = "--help" ]; then
  COMMAND="help"
fi

SELF_HOST="${MIRROR_NEURON_REDIS_LOCAL_HOST:-127.0.0.1}"
REDIS_PORT="${MIRROR_NEURON_REDIS_PORT:-6379}"
SENTINEL_PORT="${MIRROR_NEURON_REDIS_SENTINEL_PORT:-26379}"
SENTINELS="${MIRROR_NEURON_REDIS_SENTINELS:-${SELF_HOST}:${SENTINEL_PORT}}"
MASTER_NAME="${MIRROR_NEURON_REDIS_SENTINEL_MASTER:-mirror-neuron}"
QUORUM="${MIRROR_NEURON_REDIS_SENTINEL_QUORUM:-1}"
DATA_DIR="${MIRROR_NEURON_REDIS_DATA_DIR:-/tmp/mirror_neuron_redis}"
REDIS_SERVER="${MIRROR_NEURON_REDIS_SERVER_BIN:-redis-server}"
REDIS_CLI="${MIRROR_NEURON_REDIS_CLI_BIN:-redis-cli}"
REDIS_USERNAME="${MIRROR_NEURON_REDIS_USERNAME:-}"
REDIS_PASSWORD="${MIRROR_NEURON_REDIS_PASSWORD:-}"
SENTINEL_USERNAME="${MIRROR_NEURON_REDIS_SENTINEL_USERNAME:-}"
SENTINEL_PASSWORD="${MIRROR_NEURON_REDIS_SENTINEL_PASSWORD:-}"
PURGE_LOCAL="0"

usage() {
  cat <<EOF
usage:
  bash scripts/redis_ha.sh <join|leave|status> [options]

options:
      --self-host <host>          Address other boxes use for this Redis
      --redis-port <port>         Local Redis port, defaults to 6379
      --sentinel-port <port>      Local Sentinel port, defaults to 26379
      --sentinels <host:port,...> Sentinel peers, defaults to self
      --master-name <name>        Sentinel master name, defaults to mirror-neuron
      --quorum <n>                Sentinel quorum, defaults to 1 for dev clusters
      --data-dir <path>           Redis/Sentinel state dir
      --purge-local               On leave, FLUSHDB after detaching local Redis
  -h, --help                      Show this help

Environment:
  MIRROR_NEURON_REDIS_USERNAME / MIRROR_NEURON_REDIS_PASSWORD
  MIRROR_NEURON_REDIS_SENTINEL_USERNAME / MIRROR_NEURON_REDIS_SENTINEL_PASSWORD
  MIRROR_NEURON_REDIS_SERVER_BIN / MIRROR_NEURON_REDIS_CLI_BIN
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-host)
      SELF_HOST="$2"
      shift 2
      ;;
    --redis-port)
      REDIS_PORT="$2"
      shift 2
      ;;
    --sentinel-port)
      SENTINEL_PORT="$2"
      shift 2
      ;;
    --sentinels)
      SENTINELS="$2"
      shift 2
      ;;
    --master-name)
      MASTER_NAME="$2"
      shift 2
      ;;
    --quorum)
      QUORUM="$2"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --purge-local)
      PURGE_LOCAL="1"
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

if [ "$COMMAND" = "help" ]; then
  usage
  exit 0
fi

if [ "$COMMAND" != "join" ] && [ "$COMMAND" != "leave" ] && [ "$COMMAND" != "status" ]; then
  usage >&2
  exit 1
fi

need_bins() {
  command -v "$REDIS_CLI" >/dev/null 2>&1 || {
    echo "redis-cli not found; set MIRROR_NEURON_REDIS_CLI_BIN" >&2
    exit 1
  }

  if [ "$COMMAND" = "join" ]; then
    command -v "$REDIS_SERVER" >/dev/null 2>&1 || {
      echo "redis-server not found; set MIRROR_NEURON_REDIS_SERVER_BIN" >&2
      exit 1
    }
  fi
}

redis_auth_args() {
  if [ -n "$REDIS_USERNAME" ]; then
    printf '%s\0%s\0' --user "$REDIS_USERNAME"
  fi

  if [ -n "$REDIS_PASSWORD" ]; then
    printf '%s\0%s\0%s\0' -a "$REDIS_PASSWORD" --no-auth-warning
  fi
}

sentinel_auth_args() {
  if [ -n "$SENTINEL_USERNAME" ]; then
    printf '%s\0%s\0' --user "$SENTINEL_USERNAME"
  fi

  if [ -n "$SENTINEL_PASSWORD" ]; then
    printf '%s\0%s\0%s\0' -a "$SENTINEL_PASSWORD" --no-auth-warning
  fi
}

redis_cli() {
  local host="$1"
  local port="$2"
  shift 2

  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(redis_auth_args)

  "$REDIS_CLI" -h "$host" -p "$port" "${args[@]}" "$@"
}

sentinel_cli() {
  local host="$1"
  local port="$2"
  shift 2

  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(sentinel_auth_args)

  "$REDIS_CLI" -h "$host" -p "$port" "${args[@]}" "$@"
}

local_redis_up() {
  redis_cli 127.0.0.1 "$REDIS_PORT" PING >/dev/null 2>&1
}

local_sentinel_up() {
  sentinel_cli 127.0.0.1 "$SENTINEL_PORT" PING >/dev/null 2>&1
}

ensure_local_redis() {
  if local_redis_up; then
    return
  fi

  mkdir -p "$DATA_DIR/redis"

  local args=(
    --daemonize yes
    --port "$REDIS_PORT"
    --bind 0.0.0.0
    --protected-mode no
    --dir "$DATA_DIR/redis"
    --appendonly yes
  )

  if [ -n "$REDIS_PASSWORD" ]; then
    args+=(--requirepass "$REDIS_PASSWORD" --masterauth "$REDIS_PASSWORD")
  fi

  "$REDIS_SERVER" "${args[@]}"
}

ensure_local_sentinel() {
  if local_sentinel_up; then
    return
  fi

  mkdir -p "$DATA_DIR/sentinel"

  local conf="$DATA_DIR/sentinel/sentinel.conf"
  cat >"$conf" <<EOF
port $SENTINEL_PORT
bind 0.0.0.0
protected-mode no
dir $DATA_DIR/sentinel
sentinel resolve-hostnames yes
sentinel announce-hostnames no
sentinel announce-ip $SELF_HOST
sentinel announce-port $SENTINEL_PORT
EOF

  "$REDIS_SERVER" "$conf" --sentinel --daemonize yes
}

split_endpoint() {
  local endpoint="$1"
  local host="${endpoint%%:*}"
  local port="${endpoint##*:}"

  if [ "$host" = "$port" ]; then
    port="26379"
  fi

  printf '%s %s\n' "$host" "$port"
}

discover_primary() {
  local endpoints=()
  IFS=',' read -r -a endpoints <<<"$SENTINELS"

  for endpoint in "${endpoints[@]}"; do
    local host port reply primary_host primary_port
    read -r host port < <(split_endpoint "$endpoint")

    reply="$(sentinel_cli "$host" "$port" SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null || true)"
    primary_host="$(printf '%s\n' "$reply" | sed -n '1p')"
    primary_port="$(printf '%s\n' "$reply" | sed -n '2p')"

    if [ -n "$primary_host" ] && [ -n "$primary_port" ]; then
      printf '%s %s\n' "$primary_host" "$primary_port"
      return 0
    fi
  done

  return 1
}

is_self_primary() {
  local primary_host="$1"
  local primary_port="$2"

  [ "$primary_port" = "$REDIS_PORT" ] &&
    { [ "$primary_host" = "$SELF_HOST" ] || [ "$primary_host" = "127.0.0.1" ] || [ "$primary_host" = "localhost" ]; }
}

configure_sentinel() {
  local primary_host="$1"
  local primary_port="$2"

  sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL MONITOR "$MASTER_NAME" "$primary_host" "$primary_port" "$QUORUM" >/dev/null 2>&1 || true
  sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL SET "$MASTER_NAME" down-after-milliseconds 5000 >/dev/null
  sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL SET "$MASTER_NAME" failover-timeout 60000 >/dev/null
  sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL SET "$MASTER_NAME" parallel-syncs 1 >/dev/null

  if [ -n "$REDIS_PASSWORD" ]; then
    sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL SET "$MASTER_NAME" auth-pass "$REDIS_PASSWORD" >/dev/null
  fi

  if [ -n "$REDIS_USERNAME" ]; then
    sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL SET "$MASTER_NAME" auth-user "$REDIS_USERNAME" >/dev/null
  fi
}

wait_replication() {
  local attempts=60

  while [ "$attempts" -gt 0 ]; do
    local info
    info="$(redis_cli 127.0.0.1 "$REDIS_PORT" INFO replication 2>/dev/null || true)"

    if printf '%s\n' "$info" | grep -q '^role:master'; then
      return 0
    fi

    if printf '%s\n' "$info" | grep -q '^master_link_status:up'; then
      return 0
    fi

    attempts=$((attempts - 1))
    sleep 1
  done

  echo "timed out waiting for local Redis replication to become healthy" >&2
  return 1
}

wait_primary_changes() {
  local old_host="$1"
  local old_port="$2"
  local attempts=60

  while [ "$attempts" -gt 0 ]; do
    local host port
    if read -r host port < <(discover_primary); then
      if ! { [ "$host" = "$old_host" ] && [ "$port" = "$old_port" ]; }; then
        printf '%s %s\n' "$host" "$port"
        return 0
      fi
    fi

    attempts=$((attempts - 1))
    sleep 1
  done

  return 1
}

join_cluster() {
  ensure_local_redis
  ensure_local_sentinel

  local primary_host primary_port
  if ! read -r primary_host primary_port < <(discover_primary); then
    primary_host="$SELF_HOST"
    primary_port="$REDIS_PORT"
  fi

  if is_self_primary "$primary_host" "$primary_port"; then
    redis_cli 127.0.0.1 "$REDIS_PORT" REPLICAOF NO ONE >/dev/null
  else
    redis_cli 127.0.0.1 "$REDIS_PORT" REPLICAOF "$primary_host" "$primary_port" >/dev/null
  fi

  configure_sentinel "$primary_host" "$primary_port"
  wait_replication
  status
}

leave_cluster() {
  local primary_host primary_port

  if read -r primary_host primary_port < <(discover_primary); then
    if is_self_primary "$primary_host" "$primary_port"; then
      echo "local Redis is primary; asking Sentinel to fail over before leaving..."

      local endpoints=()
      IFS=',' read -r -a endpoints <<<"$SENTINELS"

      for endpoint in "${endpoints[@]}"; do
        local host port
        read -r host port < <(split_endpoint "$endpoint")
        sentinel_cli "$host" "$port" SENTINEL FAILOVER "$MASTER_NAME" >/dev/null 2>&1 || true
      done

      wait_primary_changes "$primary_host" "$primary_port" >/dev/null || {
        echo "could not confirm a new Redis primary; refusing to detach local primary" >&2
        return 1
      }
    fi
  fi

  redis_cli 127.0.0.1 "$REDIS_PORT" REPLICAOF NO ONE >/dev/null 2>&1 || true
  sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true

  if [ "$PURGE_LOCAL" = "1" ]; then
    redis_cli 127.0.0.1 "$REDIS_PORT" FLUSHDB >/dev/null
  fi

  status
}

status() {
  echo "Redis HA status"
  echo "  local redis:    127.0.0.1:$REDIS_PORT"
  echo "  local sentinel: 127.0.0.1:$SENTINEL_PORT"
  echo "  sentinels:      $SENTINELS"
  echo "  master name:    $MASTER_NAME"

  if local_redis_up; then
    redis_cli 127.0.0.1 "$REDIS_PORT" INFO replication | sed 's/^/  redis: /'
  else
    echo "  redis: down"
  fi

  if local_sentinel_up; then
    sentinel_cli 127.0.0.1 "$SENTINEL_PORT" SENTINEL get-master-addr-by-name "$MASTER_NAME" | sed 's/^/  sentinel primary: /'
  else
    echo "  sentinel: down"
  fi
}

need_bins

case "$COMMAND" in
  join) join_cluster ;;
  leave) leave_cluster ;;
  status) status ;;
esac
