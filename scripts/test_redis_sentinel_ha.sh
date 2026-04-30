#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDIS_IMAGE="${MIRROR_NEURON_REDIS_TEST_IMAGE:-redis:7}"
RUN_ID="mn-redis-ha-$$-$RANDOM"
NETWORK="$RUN_ID"
MASTER_NAME="mn-ha-$RUN_ID"
NAMESPACE="redis_ha_smoke_$RUN_ID"

find_free_port() {
  local port

  while true; do
    port=$((20000 + RANDOM % 30000))
    if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      echo "$port"
      return
    fi
  done
}

R1_PORT="$(find_free_port)"
R2_PORT="$(find_free_port)"
R3_PORT="$(find_free_port)"
S1_PORT="$(find_free_port)"
S2_PORT="$(find_free_port)"
S3_PORT="$(find_free_port)"
GRPC_PORT="$(find_free_port)"
API_PORT="$(find_free_port)"

R1="${RUN_ID}-redis-1"
R2="${RUN_ID}-redis-2"
R3="${RUN_ID}-redis-3"
S1="${RUN_ID}-sentinel-1"
S2="${RUN_ID}-sentinel-2"
S3="${RUN_ID}-sentinel-3"

cleanup() {
  docker rm -f "$R1" "$R2" "$R3" "$S1" "$S2" "$S3" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

docker run -d --name "$R1" --network "$NETWORK" \
  --add-host=host.docker.internal:host-gateway \
  -p "127.0.0.1:${R1_PORT}:6379" \
  "$REDIS_IMAGE" \
  redis-server --port 6379 --save "" --appendonly no \
  --replica-announce-ip host.docker.internal --replica-announce-port "$R1_PORT" >/dev/null

docker run -d --name "$R2" --network "$NETWORK" \
  --add-host=host.docker.internal:host-gateway \
  -p "127.0.0.1:${R2_PORT}:6379" \
  "$REDIS_IMAGE" \
  redis-server --port 6379 --save "" --appendonly no \
  --replicaof host.docker.internal "$R1_PORT" \
  --replica-announce-ip host.docker.internal --replica-announce-port "$R2_PORT" >/dev/null

docker run -d --name "$R3" --network "$NETWORK" \
  --add-host=host.docker.internal:host-gateway \
  -p "127.0.0.1:${R3_PORT}:6379" \
  "$REDIS_IMAGE" \
  redis-server --port 6379 --save "" --appendonly no \
  --replicaof host.docker.internal "$R1_PORT" \
  --replica-announce-ip host.docker.internal --replica-announce-port "$R3_PORT" >/dev/null

start_sentinel() {
  local name="$1"
  local port="$2"

  docker run -d --name "$name" --network "$NETWORK" \
    --add-host=host.docker.internal:host-gateway \
    -p "127.0.0.1:${port}:26379" \
    "$REDIS_IMAGE" \
    sh -c "cat >/tmp/sentinel.conf <<EOF
port 26379
bind 0.0.0.0
protected-mode no
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor $MASTER_NAME host.docker.internal $R1_PORT 2
sentinel down-after-milliseconds $MASTER_NAME 1000
sentinel failover-timeout $MASTER_NAME 10000
sentinel parallel-syncs $MASTER_NAME 1
EOF
redis-server /tmp/sentinel.conf --sentinel" >/dev/null
}

start_sentinel "$S1" "$S1_PORT"
start_sentinel "$S2" "$S2_PORT"
start_sentinel "$S3" "$S3_PORT"

wait_for_primary() {
  local attempts=40

  while [ "$attempts" -gt 0 ]; do
    if docker exec "$S1" redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER_NAME" >/dev/null 2>&1; then
      return
    fi

    attempts=$((attempts - 1))
    sleep 0.5
  done

  echo "sentinel did not report a primary in time" >&2
  exit 1
}

wait_for_replicas() {
  local attempts=60

  while [ "$attempts" -gt 0 ]; do
    local slaves
    slaves="$(docker exec "$R1" redis-cli INFO replication 2>/dev/null | awk '/^slave[0-9]+:/ && /state=online/ {count++} END {print count + 0}')"

    if [ "${slaves:-0}" -ge 2 ]; then
      return
    fi

    attempts=$((attempts - 1))
    sleep 1
  done

  echo "replicas did not attach to the initial Redis primary in time" >&2
  exit 1
}

wait_for_primary
wait_for_replicas

export MIRROR_NEURON_REDIS_HA_MODE="sentinel"
export MIRROR_NEURON_REDIS_SENTINELS="127.0.0.1:${S1_PORT},127.0.0.1:${S2_PORT},127.0.0.1:${S3_PORT}"
export MIRROR_NEURON_REDIS_SENTINEL_MASTER="$MASTER_NAME"
export MIRROR_NEURON_REDIS_SENTINEL_HOST_MAP="host.docker.internal=127.0.0.1"
export MIRROR_NEURON_REDIS_URL="redis://127.0.0.1:${R1_PORT}/0"
export MIRROR_NEURON_REDIS_DB="0"
export MIRROR_NEURON_REDIS_NAMESPACE="$NAMESPACE"
export MIRROR_NEURON_REDIS_WAIT_REPLICAS="1"
export MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS="1000"
export MIRROR_NEURON_GRPC_PORT="$GRPC_PORT"
export MIRROR_NEURON_API_PORT="$API_PORT"
export MN_REDIS_HA_MASTER_CONTAINER="$R1"

cd "$ROOT_DIR"

mix run -e '
alias MirrorNeuron.Persistence.RedisStore

job_id = "redis-ha-smoke-" <> Integer.to_string(System.unique_integer([:positive]))

{:ok, _job} =
  RedisStore.persist_job(job_id, %{
    "job_id" => job_id,
    "status" => "running",
    "phase" => "before_failover"
  })

IO.puts("initial_write_ok=#{job_id}")

{_output, 0} = System.cmd("docker", ["kill", System.fetch_env!("MN_REDIS_HA_MASTER_CONTAINER")])
Process.sleep(12_000)

case RedisStore.persist_job(job_id, %{
       "job_id" => job_id,
       "status" => "running",
       "phase" => "after_failover"
     }) do
  {:ok, _job} ->
    IO.puts("post_failover_write_ok")

  other ->
    raise "post-failover write failed: #{inspect(other)}"
end

{:ok, job} = RedisStore.fetch_job(job_id)

if job["phase"] != "after_failover" do
  raise "post-failover read returned stale data: #{inspect(job)}"
end

IO.puts("post_failover_read_ok")
'
