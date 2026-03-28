#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX1_IP=""
BOX2_IP=""
START=""
END=""
CHUNK_SIZE="100"
CHUNK_SIZE_EXPLICIT="0"
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
DIST_PORT="${MIRROR_NEURON_DIST_PORT:-4370}"
EXECUTOR_CAPACITY="${MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY:-2}"
REMOTE_ROOT="${MIRROR_NEURON_REMOTE_ROOT:-/Users/homer/Personal_Projects/MirrorNeuron}"
SKIP_SYNC="0"
KEEP_CLUSTER_UP="0"
WAIT_TIMEOUT_SECONDS=""
POLL_INTERVAL_SECONDS="5"
REMOTE_PATH_PREFIX='export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH";'

usage() {
  cat <<'EOF'
usage:
  bash scripts/test_cluster_prime_e2e.sh --box1-ip <ip> --box2-ip <ip> --start <n> --end <n> [options]

example:
  bash scripts/test_cluster_prime_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --start 1000003 --end 1000402

options:
      --box1-ip <ip>             IP of box 1
      --box2-ip <ip>             IP of box 2
      --start <n>                Inclusive prime range start
      --end <n>                  Inclusive prime range end
      --chunk-size <n>           Numbers assigned per worker, defaults to 100
      --remote-root <path>       MirrorNeuron checkout on box 2
      --cookie <cookie>          Erlang cookie, defaults to mirrorneuron
      --dist-port <port>         Erlang distribution port, defaults to 4370
      --executor-capacity <n>    Executor lease cap per node, defaults to 2
      --wait-timeout-seconds <n> Maximum time to wait for job completion
      --poll-interval-seconds <n>
                                 Progress poll interval while waiting, defaults to 5
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
    --start)
      START="$2"
      shift 2
      ;;
    --end)
      END="$2"
      shift 2
      ;;
    --chunk-size)
      CHUNK_SIZE="$2"
      CHUNK_SIZE_EXPLICIT="1"
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
    --executor-capacity)
      EXECUTOR_CAPACITY="$2"
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

if [ -z "$BOX1_IP" ] || [ -z "$BOX2_IP" ] || [ -z "$START" ] || [ -z "$END" ]; then
  usage >&2
  exit 1
fi

if [ "$END" -lt "$START" ]; then
  echo "--end must be greater than or equal to --start" >&2
  exit 1
fi

TOTAL_CLUSTER_CAPACITY=$((EXECUTOR_CAPACITY * 2))

if [ "$CHUNK_SIZE_EXPLICIT" != "1" ]; then
  CHUNK_SIZE="$(
    python3 - <<PY
import math
start = int("$START")
end = int("$END")
capacity = max(1, int("$TOTAL_CLUSTER_CAPACITY"))
range_size = (end - start) + 1
target_workers = min(128, max(capacity * 10, 24))
chunk = max(100, math.ceil(range_size / target_workers))
print(chunk)
PY
  )"
fi

WORKERS="$(
  python3 - <<PY
start = int("$START")
end = int("$END")
chunk = int("$CHUNK_SIZE")
print(((end - start) // chunk) + 1)
PY
)"

if [ -z "$WAIT_TIMEOUT_SECONDS" ]; then
  WAIT_TIMEOUT_SECONDS="$(
    python3 - <<PY
import math
workers = int("$WORKERS")
capacity = max(1, int("$TOTAL_CLUSTER_CAPACITY"))
estimated = math.ceil((workers * 2.0) / capacity) + 120
print(max(120, estimated))
PY
  )"
fi

LOCAL_LOG="/tmp/mirror_neuron_mn1_e2e.log"
REMOTE_LOG="/tmp/mirror_neuron_mn2_e2e.log"
BUNDLE_ROOT="/tmp/mirror_neuron_cluster_bundles"

local_runtime_pids() {
  pgrep -f 'mirror_neuron.*server' || true
}

remote_runtime_pids() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX pgrep -f 'mirror_neuron.*server' || true"
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

cleanup_sandboxes_local() {
  if ! command -v openshell >/dev/null 2>&1; then
    return
  fi

  local names
  names="$(
    NO_COLOR=1 openshell sandbox list 2>/dev/null \
      | awk 'NR > 1 && (index($1, "prime-worker-") == 1 || index($1, "mirror-neuron-job-") == 1) {print $1}'
  )"

  if [ -n "$names" ]; then
    echo "Deleting local benchmark sandboxes..."
    printf '%s\n' "$names" | xargs -n 20 openshell sandbox delete >/dev/null 2>&1 || true
  fi
}

cleanup_sandboxes_remote() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
    if command -v openshell >/dev/null 2>&1; then
      names=\$(
        NO_COLOR=1 openshell sandbox list 2>/dev/null \
          | awk 'NR > 1 && (index(\$1, \"prime-worker-\") == 1 || index(\$1, \"mirror-neuron-job-\") == 1) {print \$1}'
      )
      if [ -n \"\$names\" ]; then
        printf \"%s\n\" \"\$names\" | xargs -n 20 openshell sandbox delete >/dev/null 2>&1 || true
      fi
    fi
  "
}

ensure_local_gateway() {
  if openshell status >/dev/null 2>&1; then
    return
  fi

  openshell gateway start >/dev/null
}

ensure_remote_gateway() {
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX
    if openshell status >/dev/null 2>&1; then
      exit 0
    fi
    openshell gateway start >/dev/null
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
      MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY="$EXECUTOR_CAPACITY" \
      MIRROR_NEURON_DIST_PORT="$DIST_PORT" \
      ERL_AFLAGS="-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}" \
      MIRROR_NEURON_LOG_PATH="$LOCAL_LOG" \
      python3 - <<'PY'
import os
import subprocess

log_path = os.environ["MIRROR_NEURON_LOG_PATH"]
with open(log_path, "ab", buffering=0) as log_file:
    proc = subprocess.Popen(
        ["./mirror_neuron", "server"],
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
      MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY=\"$EXECUTOR_CAPACITY\" \
      MIRROR_NEURON_DIST_PORT=\"$DIST_PORT\" \
      ERL_AFLAGS=\"-kernel inet_dist_listen_min ${DIST_PORT} inet_dist_listen_max ${DIST_PORT}\" \
      MIRROR_NEURON_LOG_PATH=\"$REMOTE_LOG\" \
      python3 - <<'PY'
import os
import subprocess

log_path = os.environ[\"MIRROR_NEURON_LOG_PATH\"]
with open(log_path, \"ab\", buffering=0) as log_file:
    proc = subprocess.Popen(
        [\"./mirror_neuron\", \"server\"],
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

  echo "Cleaning up runtimes and test sandboxes..."
  stop_runtime_local
  stop_runtime_remote
  cleanup_sandboxes_local
  cleanup_sandboxes_remote
}

trap cleanup_all EXIT

stop_runtime_local
stop_runtime_remote
cleanup_sandboxes_local
cleanup_sandboxes_remote
ensure_local_gateway
ensure_remote_gateway
sync_remote_repo
build_local
build_remote
start_local_runtime
start_remote_runtime
force_cluster_connect
wait_for_cluster

echo "Running cluster prime smoke test..."
BUNDLE_PATH="$(
  python3 "$ROOT_DIR/examples/prime_sweep_scale/generate_bundle.py" \
    --workers "$WORKERS" \
    --start "$START" \
    --end "$END" \
    --chunk-size "$CHUNK_SIZE" \
    --output-dir "$BUNDLE_ROOT"
)"

RESULT_PATH="$BUNDLE_PATH/result.json"

echo "Generated bundle:"
echo "  $BUNDLE_PATH"
echo "Syncing bundle to peer box:"
echo "  peer=$BOX2_IP"
ssh "$BOX2_IP" "mkdir -p \"$(dirname "$BUNDLE_PATH")\" && rm -rf \"$BUNDLE_PATH\""
scp -r "$BUNDLE_PATH" "${BOX2_IP}:$(dirname "$BUNDLE_PATH")/" >/dev/null

echo "Range:"
echo "  $START - $END"
if [ "$CHUNK_SIZE_EXPLICIT" != "1" ]; then
  echo "Chunk size:"
  echo "  $CHUNK_SIZE (auto-selected)"
else
  echo "Chunk size:"
  echo "  $CHUNK_SIZE"
fi
echo "Validating bundle..."
bash "$ROOT_DIR/scripts/cluster_cli.sh" \
  --box1-ip "$BOX1_IP" \
  --box2-ip "$BOX2_IP" \
  --self-ip "$BOX1_IP" \
  -- validate "$BUNDLE_PATH" >/dev/null

echo "Submitting prime job through cluster CLI..."
SUBMIT_JSON="$(
  bash "$ROOT_DIR/scripts/cluster_cli.sh" \
    --box1-ip "$BOX1_IP" \
    --box2-ip "$BOX2_IP" \
    --self-ip "$BOX1_IP" \
    -- run "$BUNDLE_PATH" --json --no-await
)"

JOB_ID="$(
  printf '%s\n' "$SUBMIT_JSON" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])'
)"

echo "Submitted job:"
echo "  $JOB_ID"
echo "Waiting for completion..."
echo "  timeout: ${WAIT_TIMEOUT_SECONDS}s"
echo "  poll interval: ${POLL_INTERVAL_SECONDS}s"

JOB_JSON="$(
  cd "$ROOT_DIR"
  env \
    MIRROR_NEURON_REDIS_URL="redis://${BOX1_IP}:6379/0" \
    mix run --no-start -e '
      Application.ensure_all_started(:mirror_neuron)
      job_id = System.argv() |> List.first()
      timeout_seconds =
        System.argv()
        |> Enum.at(1)
        |> String.to_integer()

      poll_interval_ms =
        System.argv()
        |> Enum.at(2)
        |> String.to_integer()
        |> Kernel.*(1_000)

      deadline = System.monotonic_time(:millisecond) + timeout_seconds * 1_000

      wait = fn wait ->
        case MirrorNeuron.inspect_job(job_id) do
          {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
            IO.puts(Jason.encode!(job))

          _ ->
            progress =
              case MirrorNeuron.inspect_agents(job_id) do
                {:ok, agents} ->
                  execs = Enum.filter(agents, &(&1["agent_type"] == "executor"))
                  done = Enum.count(execs, &(get_in(&1, ["current_state", "runs"]) == 1))
                  agg = Enum.find(agents, &(&1["agent_id"] == "aggregator"))
                  agg_count = if agg, do: length(get_in(agg, ["current_state", "messages"]) || []), else: 0
                  "progress executors=#{done}/#{length(execs)} aggregator=#{agg_count}"

                _ ->
                  "progress unavailable"
              end

            IO.puts(:stderr, progress)

            if System.monotonic_time(:millisecond) >= deadline do
              IO.puts(:stderr, "timed out waiting for job #{job_id}")
              System.halt(2)
            else
              Process.sleep(poll_interval_ms)
              wait.(wait)
            end
        end
      end

      wait.(wait)
    ' -- "$JOB_ID" "$WAIT_TIMEOUT_SECONDS" "$POLL_INTERVAL_SECONDS"
)"

printf '%s\n' "$JOB_JSON" >"$RESULT_PATH"

echo "Result written to:"
echo "  $RESULT_PATH"
echo "Summary:"
python3 "$ROOT_DIR/examples/prime_sweep_scale/summarize_result.py" "$RESULT_PATH"

echo "Worker placement by node:"
(
  cd "$ROOT_DIR"
  env \
    MIRROR_NEURON_REDIS_URL="redis://${BOX1_IP}:6379/0" \
    mix run --no-start -e '
      Application.ensure_all_started(:mirror_neuron)
      job_id = System.argv() |> List.first()

      case MirrorNeuron.inspect_agents(job_id) do
        {:ok, agents} ->
          agents
          |> Enum.filter(&(&1["agent_type"] == "executor"))
          |> Enum.group_by(& &1["assigned_node"])
          |> Enum.sort_by(fn {node, _agents} -> node end)
          |> Enum.each(fn {node, node_agents} ->
            IO.puts("  #{node}: #{length(node_agents)} executor(s)")
          end)

        {:error, reason} ->
          IO.puts(:stderr, "Could not inspect agent placement: #{inspect(reason)}")
          System.halt(1)
      end
    ' -- "$JOB_ID"
)

echo "End-to-end cluster test completed."
