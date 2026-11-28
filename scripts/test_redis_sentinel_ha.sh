#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDIS_IMAGE="${MN_REDIS_TEST_IMAGE:-docker.io/library/redis:7}"
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
AUTH_FILE=""

cleanup() {
  podman rm -f "$R1" "$R2" "$R3" "$S1" "$S2" "$S3" >/dev/null 2>&1 || true
  podman network rm "$NETWORK" >/dev/null 2>&1 || true
  if [ -n "$AUTH_FILE" ]; then rm -f -- "$AUTH_FILE"; fi
}

trap cleanup EXIT

if [ -z "${MN_REDIS_TEST_IMAGE:-}" ] && [ -z "${REGISTRY_AUTH_FILE:-}" ]; then
  AUTH_FILE="$(mktemp "${TMPDIR:-/tmp}/mn-redis-ha-auth.XXXXXXXX")"
  printf '%s\n' '{"auths":{}}' >"$AUTH_FILE"
  export REGISTRY_AUTH_FILE="$AUTH_FILE"
fi

podman network create "$NETWORK" >/dev/null

# Peers resolve container names on the private network. Core reaches the
# same announced ports through its loopback-only publications.
start_redis() {
  local name="$1" port="$2"
  shift 2
  podman run -d --name "$name" --network "$NETWORK" -p "127.0.0.1:$port:$port" \
    "$REDIS_IMAGE" redis-server --port "$port" --save "" --appendonly no \
    --replica-announce-ip "$name" --replica-announce-port "$port" "$@" >/dev/null
}

start_redis "$R1" "$R1_PORT"
start_redis "$R2" "$R2_PORT" --replicaof "$R1" "$R1_PORT"
start_redis "$R3" "$R3_PORT" --replicaof "$R1" "$R1_PORT"

start_sentinel() {
  local name="$1"
  local port="$2"

  podman run -d --name "$name" --network "$NETWORK" \
    -p "127.0.0.1:$port:26379" \
    "$REDIS_IMAGE" \
    sh -c "cat >/tmp/sentinel.conf <<EOF
port 26379
bind 0.0.0.0
protected-mode no
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor $MASTER_NAME $R1 $R1_PORT 2
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
  local attempts=40 address

  while [ "$attempts" -gt 0 ]; do
    if address="$(podman exec "$S1" redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null)" &&
      [ "$address" = "$(printf '%s\n%s' "$R1" "$R1_PORT")" ]; then
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
    slaves="$(podman exec "$R1" redis-cli -p "$R1_PORT" INFO replication 2>/dev/null | awk '/^slave[0-9]+:/ && /state=online/ {count++} END {print count + 0}')"

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

export MN_REDIS_HA_MODE="sentinel"
export MN_REDIS_SENTINELS="127.0.0.1:${S1_PORT},127.0.0.1:${S2_PORT},127.0.0.1:${S3_PORT}"
export MN_REDIS_SENTINEL_MASTER="$MASTER_NAME"
export MN_REDIS_SENTINEL_HOST_MAP="$R1=127.0.0.1,$R2=127.0.0.1,$R3=127.0.0.1"
export MN_REDIS_URL="redis://127.0.0.1:${R1_PORT}/0"
export MN_REDIS_DB="0"
export MN_REDIS_NAMESPACE="$NAMESPACE"
export MN_REDIS_WAIT_REPLICAS="1"
export MN_REDIS_WAIT_TIMEOUT_MS="1000"
export MN_GRPC_PORT="$GRPC_PORT"
export MN_API_PORT="$API_PORT"
export MN_REDIS_HA_MASTER_CONTAINER="$R1"
export MN_REDIS_HA_SENTINEL_CONTAINER="$S1"
export MN_REDIS_HA_REPLICA_CONTAINERS="$R2,$R3"

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

{_output, 0} = System.cmd("podman", ["kill", System.fetch_env!("MN_REDIS_HA_MASTER_CONTAINER")])
sentinel = System.fetch_env!("MN_REDIS_HA_SENTINEL_CONTAINER")
master = System.fetch_env!("MN_REDIS_SENTINEL_MASTER")
replicas = String.split(System.fetch_env!("MN_REDIS_HA_REPLICA_CONTAINERS"), ",")
deadline = System.monotonic_time(:millisecond) + 30_000

wait_for_failover = fn wait ->
  {output, status} = System.cmd("podman", ["exec", sentinel, "redis-cli", "-p", "26379", "--raw", "SENTINEL", "get-master-addr-by-name", master], stderr_to_stdout: true)

  case {status, String.split(String.trim(output), "\n")} do
    {0, [host, _port]} when host != "" ->
      if host in replicas do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline, do: raise("Sentinel retained the original master")
        Process.sleep(250)
        wait.(wait)
      end

    _ ->
      if System.monotonic_time(:millisecond) >= deadline, do: raise("Sentinel did not report a promoted replica")
      Process.sleep(250)
      wait.(wait)
  end
end

:ok = wait_for_failover.(wait_for_failover)

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
