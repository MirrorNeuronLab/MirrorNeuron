#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_HOST=""
LOCAL_IP="${MIRROR_NEURON_REDIS_HA_LOCAL_IP:-}"
REMOTE_IP="${MIRROR_NEURON_REDIS_HA_REMOTE_IP:-}"
REDIS_PORT="${MIRROR_NEURON_REDIS_HA_TEST_REDIS_PORT:-46379}"
SENTINEL_PORT="${MIRROR_NEURON_REDIS_HA_TEST_SENTINEL_PORT:-46380}"
REDIS_IMAGE="${MIRROR_NEURON_REDIS_TEST_IMAGE:-redis:7}"
SSH_OPTS="${MIRROR_NEURON_REDIS_HA_TEST_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}"
REMOTE_NETWORK="${MIRROR_NEURON_REDIS_HA_TEST_REMOTE_NETWORK:-auto}"
INITIAL_PRIMARY="${MIRROR_NEURON_REDIS_HA_TEST_INITIAL_PRIMARY:-auto}"

usage() {
  cat <<EOF
usage:
  bash scripts/test_redis_sentinel_two_box_ha.sh --remote-host <host> [options]

options:
      --local-ip <ip>       Local box IP reachable from the remote box.
      --remote-ip <ip>      Remote box IP reachable from the local box. Defaults to --remote-host.
      --redis-port <port>   Host Redis port to expose on both boxes. Defaults to 46379.
      --sentinel-port <p>   Host Sentinel port to expose on both boxes. Defaults to 46380.
      --redis-image <img>   Docker image. Defaults to redis:7.
      --remote-network <n>  Remote Docker network mode: auto, host, or bridge. Defaults to auto.
      --initial-primary <p> Initial primary: auto, local, or remote. Defaults to auto.
  -h, --help                Show this help.

The test starts Redis + Sentinel in Docker on both boxes, writes through MirrorNeuron,
kills the initial primary Redis, waits for Sentinel failover, then verifies a post-failover
MirrorNeuron write/read succeeds against the promoted replica.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"
      shift 2
      ;;
    --local-ip)
      LOCAL_IP="$2"
      shift 2
      ;;
    --remote-ip)
      REMOTE_IP="$2"
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
    --redis-image)
      REDIS_IMAGE="$2"
      shift 2
      ;;
    --remote-network)
      REMOTE_NETWORK="$2"
      shift 2
      ;;
    --initial-primary)
      INITIAL_PRIMARY="$2"
      shift 2
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

if [ -z "$REMOTE_HOST" ]; then
  echo "--remote-host is required" >&2
  usage >&2
  exit 1
fi

if [ -z "$REMOTE_IP" ]; then
  REMOTE_IP="$REMOTE_HOST"
fi

detect_local_ip() {
  if command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
    return
  fi

  if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    hostname -I | awk '{print $1}'
    return
  fi

  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig | awk '/inet / && $2 !~ /^127\./ {print $2; exit}'
  fi
}

if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP="$(detect_local_ip)"
fi

if [ -z "$LOCAL_IP" ]; then
  echo "could not determine local IP; pass --local-ip" >&2
  exit 1
fi

ssh_remote() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$REMOTE_HOST" "$@"
}

find_free_local_port() {
  local port

  while true; do
    port=$((20000 + RANDOM % 30000))
    if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      echo "$port"
      return
    fi
  done
}

ensure_port_free() {
  local host="$1"
  local port="$2"
  local label="$3"

  if nc -z "$host" "$port" >/dev/null 2>&1; then
    echo "$label port $host:$port is already in use" >&2
    exit 1
  fi
}

ensure_remote_port_free() {
  local port="$1"
  local label="$2"

  if ssh_remote "nc -z 127.0.0.1 '$port' >/dev/null 2>&1"; then
    echo "$label port on remote 127.0.0.1:$port is already in use" >&2
    exit 1
  fi
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

require_bin docker
require_bin ssh
require_bin nc

ssh_remote "command -v docker >/dev/null && command -v nc >/dev/null"

case "$REMOTE_NETWORK" in
  auto|host|bridge)
    ;;
  *)
    echo "--remote-network must be auto, host, or bridge" >&2
    exit 1
    ;;
esac

case "$INITIAL_PRIMARY" in
  auto|local|remote)
    ;;
  *)
    echo "--initial-primary must be auto, local, or remote" >&2
    exit 1
    ;;
esac

if [ "$REMOTE_NETWORK" = "auto" ]; then
  remote_docker_os="$(ssh_remote "docker info --format '{{.OSType}}'")"
  if [ "$remote_docker_os" = "linux" ]; then
    REMOTE_NETWORK="host"
  else
    REMOTE_NETWORK="bridge"
  fi
fi

ensure_port_free 127.0.0.1 "$REDIS_PORT" "local Redis"
ensure_port_free 127.0.0.1 "$SENTINEL_PORT" "local Sentinel"
ensure_remote_port_free "$REDIS_PORT" "Redis"
ensure_remote_port_free "$SENTINEL_PORT" "Sentinel"

GRPC_PORT="$(find_free_local_port)"
API_PORT="$(find_free_local_port)"
RUN_ID="mn-redis-2box-$$-$RANDOM"
MASTER_NAME="mn-two-box-$RUN_ID"
LOCAL_REDIS="$RUN_ID-local-redis"
LOCAL_SENTINEL="$RUN_ID-local-sentinel"
REMOTE_REDIS="$RUN_ID-remote-redis"
REMOTE_SENTINEL="$RUN_ID-remote-sentinel"
LOCAL_REDIS_ANNOUNCE_IP="$LOCAL_IP"

cleanup() {
  docker rm -f "$LOCAL_REDIS" "$LOCAL_SENTINEL" >/dev/null 2>&1 || true
  ssh_remote "docker rm -f '$REMOTE_REDIS' '$REMOTE_SENTINEL' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

trap cleanup EXIT
cleanup

echo "Starting two-box Redis Sentinel HA smoke"
echo "  local:  $LOCAL_IP"
echo "  remote: $REMOTE_IP via $REMOTE_HOST"
echo "  redis:  $REDIS_PORT"
echo "  sentinel: $SENTINEL_PORT"
echo "  remote docker network: $REMOTE_NETWORK"
echo "  initial primary: $INITIAL_PRIMARY"

start_local_redis() {
  if [ "$1" = "replica" ]; then
    docker run -d --name "$LOCAL_REDIS" \
      -p "0.0.0.0:${REDIS_PORT}:6379" \
      "$REDIS_IMAGE" \
      redis-server --port 6379 --save "" --appendonly no \
      --protected-mode no \
      --replicaof "$REMOTE_IP" "$REDIS_PORT" \
      --replica-announce-ip "$LOCAL_REDIS_ANNOUNCE_IP" \
      --replica-announce-port "$REDIS_PORT" >/dev/null
  else
    docker run -d --name "$LOCAL_REDIS" \
      -p "0.0.0.0:${REDIS_PORT}:6379" \
      "$REDIS_IMAGE" \
      redis-server --port 6379 --save "" --appendonly no \
      --protected-mode no \
      --replica-announce-ip "$LOCAL_REDIS_ANNOUNCE_IP" \
      --replica-announce-port "$REDIS_PORT" >/dev/null
  fi
}

start_remote_redis() {
  local mode="$1"
  local port="6379"
  local network_args="-p '0.0.0.0:${REDIS_PORT}:6379'"
  local replica_args=""

  if [ "$REMOTE_NETWORK" = "host" ]; then
    port="$REDIS_PORT"
    network_args="--network host"
  fi

  if [ "$mode" = "replica" ]; then
    replica_args="--replicaof '$LOCAL_IP' '$REDIS_PORT'"
  fi

  ssh_remote "docker run -d --name '$REMOTE_REDIS' \
    $network_args \
    '$REDIS_IMAGE' \
    redis-server --port '$port' --save '' --appendonly no \
    --protected-mode no \
    $replica_args \
    --replica-announce-ip '$REMOTE_IP' --replica-announce-port '$REDIS_PORT'" >/dev/null
}

start_local_redis primary

if [ "$INITIAL_PRIMARY" = "auto" ]; then
  if ssh_remote "nc -z -w 3 '$LOCAL_IP' '$REDIS_PORT' >/dev/null 2>&1"; then
    INITIAL_PRIMARY="local"
  else
    echo "Remote cannot reach local Redis at $LOCAL_IP:$REDIS_PORT; using remote as initial primary."
    INITIAL_PRIMARY="remote"
  fi
fi

if [ "$INITIAL_PRIMARY" = "local" ]; then
  PRIMARY_IP="$LOCAL_IP"
  PRIMARY_REDIS="$LOCAL_REDIS"
  start_remote_redis replica
else
  PRIMARY_IP="$REMOTE_IP"
  PRIMARY_REDIS="$REMOTE_REDIS"
  LOCAL_REDIS_ANNOUNCE_IP="host.docker.internal"
  docker rm -f "$LOCAL_REDIS" >/dev/null 2>&1 || true
  start_remote_redis primary
  start_local_redis replica
fi

docker run -d --name "$LOCAL_SENTINEL" \
  --add-host=host.docker.internal:host-gateway \
  -p "0.0.0.0:${SENTINEL_PORT}:26379" \
  "$REDIS_IMAGE" \
  sh -c "cat >/tmp/sentinel.conf <<EOF
port 26379
bind 0.0.0.0
protected-mode no
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $LOCAL_IP
sentinel announce-port $SENTINEL_PORT
sentinel monitor $MASTER_NAME $PRIMARY_IP $REDIS_PORT 1
sentinel down-after-milliseconds $MASTER_NAME 1000
sentinel failover-timeout $MASTER_NAME 10000
sentinel parallel-syncs $MASTER_NAME 1
EOF
redis-server /tmp/sentinel.conf --sentinel" >/dev/null

if [ "$INITIAL_PRIMARY" = "local" ]; then
  if [ "$REMOTE_NETWORK" = "host" ]; then
    ssh_remote "docker run -d --name '$REMOTE_SENTINEL' \
      --network host \
      '$REDIS_IMAGE' \
      sh -c 'cat >/tmp/sentinel.conf <<EOF
port $SENTINEL_PORT
bind 0.0.0.0
protected-mode no
sentinel announce-ip $REMOTE_IP
sentinel announce-port $SENTINEL_PORT
sentinel monitor $MASTER_NAME $PRIMARY_IP $REDIS_PORT 1
sentinel down-after-milliseconds $MASTER_NAME 1000
sentinel failover-timeout $MASTER_NAME 10000
sentinel parallel-syncs $MASTER_NAME 1
EOF
redis-server /tmp/sentinel.conf --sentinel'" >/dev/null
  else
    ssh_remote "docker run -d --name '$REMOTE_SENTINEL' \
      -p '0.0.0.0:${SENTINEL_PORT}:26379' \
      '$REDIS_IMAGE' \
      sh -c 'cat >/tmp/sentinel.conf <<EOF
port 26379
bind 0.0.0.0
protected-mode no
sentinel announce-ip $REMOTE_IP
sentinel announce-port $SENTINEL_PORT
sentinel monitor $MASTER_NAME $PRIMARY_IP $REDIS_PORT 1
sentinel down-after-milliseconds $MASTER_NAME 1000
sentinel failover-timeout $MASTER_NAME 10000
sentinel parallel-syncs $MASTER_NAME 1
EOF
redis-server /tmp/sentinel.conf --sentinel'" >/dev/null
  fi
fi

echo "Waiting for replica to become online..."
for _attempt in {1..60}; do
  if [ "$INITIAL_PRIMARY" = "local" ]; then
    online="$(
      docker exec "$PRIMARY_REDIS" redis-cli INFO replication 2>/dev/null |
        awk '/^slave[0-9]+:/ && /state=online/ {count++} END {print count + 0}'
    )"
  else
    remote_cli_port="6379"
    if [ "$REMOTE_NETWORK" = "host" ]; then
      remote_cli_port="$REDIS_PORT"
    fi

    online="$(
      ssh_remote "docker exec '$PRIMARY_REDIS' redis-cli -p '$remote_cli_port' INFO replication 2>/dev/null" |
        awk '/^slave[0-9]+:/ && /state=online/ {count++} END {print count + 0}'
    )"
  fi

  if [ "${online:-0}" -ge 1 ]; then
    break
  fi

  sleep 1
done

if [ "$INITIAL_PRIMARY" = "local" ]; then
  online="$(
    docker exec "$PRIMARY_REDIS" redis-cli INFO replication |
      awk '/^slave[0-9]+:/ && /state=online/ {count++} END {print count + 0}'
  )"
else
  remote_cli_port="6379"
  if [ "$REMOTE_NETWORK" = "host" ]; then
    remote_cli_port="$REDIS_PORT"
  fi

  online="$(
    ssh_remote "docker exec '$PRIMARY_REDIS' redis-cli -p '$remote_cli_port' INFO replication" |
      awk '/^slave[0-9]+:/ && /state=online/ {count++} END {print count + 0}'
  )"
fi

if [ "${online:-0}" -lt 1 ]; then
  echo "replica did not become online for initial $INITIAL_PRIMARY primary" >&2
  exit 1
fi

for _attempt in {1..30}; do
  if docker exec "$LOCAL_SENTINEL" redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER_NAME" >/dev/null 2>&1; then
    break
  fi

  sleep 1
done

export MIRROR_NEURON_REDIS_HA_MODE="sentinel"
if [ "$INITIAL_PRIMARY" = "remote" ]; then
  export MIRROR_NEURON_REDIS_SENTINELS="127.0.0.1:${SENTINEL_PORT}"
else
  export MIRROR_NEURON_REDIS_SENTINELS="127.0.0.1:${SENTINEL_PORT},${REMOTE_IP}:${SENTINEL_PORT}"
fi
export MIRROR_NEURON_REDIS_SENTINEL_MASTER="$MASTER_NAME"
export MIRROR_NEURON_REDIS_URL="redis://${PRIMARY_IP}:${REDIS_PORT}/0"
if [ "$INITIAL_PRIMARY" = "remote" ]; then
  export MIRROR_NEURON_REDIS_SENTINEL_HOST_MAP="host.docker.internal=127.0.0.1"
fi
export MIRROR_NEURON_REDIS_DB="0"
export MIRROR_NEURON_REDIS_NAMESPACE="redis_2box_$RUN_ID"
export MIRROR_NEURON_REDIS_WAIT_REPLICAS="0"
export MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS="${MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS:-20}"
export MIRROR_NEURON_GRPC_PORT="$GRPC_PORT"
export MIRROR_NEURON_API_PORT="$API_PORT"
export MN_TWO_BOX_LOCAL_REDIS="$LOCAL_REDIS"
export MN_TWO_BOX_REMOTE_REDIS="$REMOTE_REDIS"
export MN_TWO_BOX_REMOTE_HOST="$REMOTE_HOST"
export MN_TWO_BOX_INITIAL_PRIMARY="$INITIAL_PRIMARY"

cd "$ROOT_DIR"

mix run -e '
alias MirrorNeuron.Persistence.RedisStore

job_id = "redis-two-box-" <> Integer.to_string(System.unique_integer([:positive]))

{:ok, _job} =
  RedisStore.persist_job(job_id, %{
    "job_id" => job_id,
    "status" => "running",
    "phase" => "local-primary"
  })

IO.puts("two_box_initial_write_ok=#{job_id}")

case System.fetch_env!("MN_TWO_BOX_INITIAL_PRIMARY") do
  "remote" ->
    {_output, 0} =
      System.cmd("ssh", [
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        System.fetch_env!("MN_TWO_BOX_REMOTE_HOST"),
        "docker",
        "kill",
        System.fetch_env!("MN_TWO_BOX_REMOTE_REDIS")
      ])

  _ ->
    {_output, 0} = System.cmd("docker", ["kill", System.fetch_env!("MN_TWO_BOX_LOCAL_REDIS")])
end

Process.sleep(12_000)

{:ok, _job} =
  RedisStore.persist_job(job_id, %{
    "job_id" => job_id,
    "status" => "running",
    "phase" => "remote-promoted"
  })

{:ok, job} = RedisStore.fetch_job(job_id)

if job["phase"] != "remote-promoted" do
  raise "two-box stale read: #{inspect(job)}"
end

IO.puts("two_box_post_failover_write_read_ok")
'
