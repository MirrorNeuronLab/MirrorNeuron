#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/examples/ecosystem_simulation"
BUNDLE_ROOT="/tmp/mirror_neuron_cluster_bundles"
ANIMALS="2000"
REGIONS="16"
DURATION_SECONDS="300"
TICK_SECONDS="5"
MAX_FOOD="1000"
FOOD_REGEN_PER_TICK="800"
MAX_REGION_POPULATION="400"
MIGRATION_RATE="0.035"
MUTATION_RATE="0.05"
TICK_DELAY_MS=""
SEED=""
DRY_RUN="0"
WATCH="0"
BOX1_IP=""
BOX2_IP=""
SELF_IP=""
COOKIE="${MIRROR_NEURON_COOKIE:-mirrorneuron}"
DIST_PORT="${MIRROR_NEURON_DIST_PORT:-4370}"
REMOTE_ROOT="${MIRROR_NEURON_REMOTE_ROOT:-/Users/homer/Personal_Projects/MirrorNeuron}"
AUTO_START_CLUSTER="1"
KEEP_CLUSTER_UP="0"
WAIT_TIMEOUT_SECONDS="${MIRROR_NEURON_SIM_WAIT_TIMEOUT_SECONDS:-420}"
POLL_INTERVAL_SECONDS="${MIRROR_NEURON_SIM_POLL_INTERVAL_SECONDS:-5}"
WATCH_INTERVAL_SECONDS="${MIRROR_NEURON_SIM_WATCH_INTERVAL_SECONDS:-2}"
REDIS_URL="${MIRROR_NEURON_REDIS_URL:-redis://127.0.0.1:6379/0}"
REMOTE_PATH_PREFIX='export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH";'
LOCAL_CLUSTER_LOG="/tmp/mirror_neuron_mn1_ecosim_oneshot.log"
REMOTE_CLUSTER_LOG="/tmp/mirror_neuron_mn2_ecosim_oneshot.log"
STARTED_CLUSTER="0"
REDIS_CONTAINER_NAME="${MIRROR_NEURON_REDIS_CONTAINER_NAME:-mirror-neuron-redis}"

usage() {
  cat <<'EOF'
usage:
  bash examples/ecosystem_simulation/run_simulation_e2e.sh [options]

examples:
  bash examples/ecosystem_simulation/run_simulation_e2e.sh
  bash examples/ecosystem_simulation/run_simulation_e2e.sh --animals 2000 --regions 16
  bash examples/ecosystem_simulation/run_simulation_e2e.sh --animals 800 --regions 8 --watch
  bash examples/ecosystem_simulation/run_simulation_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29

options:
      --animals <n>                Total animals, defaults to 2000
      --regions <n>                Region agents, defaults to 16
      --duration-seconds <n>       Simulated duration, defaults to 300
      --tick-seconds <n>           Simulated seconds per tick, defaults to 5
      --max-food <n>               Region food capacity, defaults to 420
      --food-regen-per-tick <n>    Food regenerated per tick, defaults to 72
      --max-region-population <n>  Soft population cap per region, defaults to 220
      --migration-rate <n>         Base migration rate, defaults to 0.035
      --mutation-rate <n>          DNA mutation rate, defaults to 0.05
      --tick-delay-ms <n>         Real wall-clock delay per tick for watched demos
      --seed <n>                   Simulation seed, defaults to a random value per run
      --box1-ip <ip>               Submit through cluster_cli.sh using box 1
      --box2-ip <ip>               Submit through cluster_cli.sh using box 2
      --self-ip <ip>               Submit through cluster_cli.sh from this machine
      --cookie <cookie>            Erlang cookie, defaults to mirrorneuron
      --dist-port <port>           Erlang distribution port, defaults to 4370
      --remote-root <path>         MirrorNeuron checkout on box 2
      --no-auto-start-cluster      Do not start cluster runtimes automatically
      --keep-cluster-up            Leave auto-started runtimes running after the job
      --wait-timeout-seconds <n>   Maximum time to wait, defaults to 420
      --poll-interval-seconds <n>  Progress poll interval, defaults to 5
      --watch                      Render the ASCII dashboard while the job runs
      --watch-interval-seconds <n> Dashboard refresh interval, defaults to 2
      --dry-run                    Generate only; do not run
  -h, --help                       Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --animals) ANIMALS="$2"; shift 2 ;;
    --regions) REGIONS="$2"; shift 2 ;;
    --duration-seconds) DURATION_SECONDS="$2"; shift 2 ;;
    --tick-seconds) TICK_SECONDS="$2"; shift 2 ;;
    --max-food) MAX_FOOD="$2"; shift 2 ;;
    --food-regen-per-tick) FOOD_REGEN_PER_TICK="$2"; shift 2 ;;
    --max-region-population) MAX_REGION_POPULATION="$2"; shift 2 ;;
    --migration-rate) MIGRATION_RATE="$2"; shift 2 ;;
    --mutation-rate) MUTATION_RATE="$2"; shift 2 ;;
    --tick-delay-ms) TICK_DELAY_MS="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --box1-ip) BOX1_IP="$2"; shift 2 ;;
    --box2-ip) BOX2_IP="$2"; shift 2 ;;
    --self-ip) SELF_IP="$2"; shift 2 ;;
    --cookie) COOKIE="$2"; shift 2 ;;
    --dist-port) DIST_PORT="$2"; shift 2 ;;
    --remote-root) REMOTE_ROOT="$2"; shift 2 ;;
    --no-auto-start-cluster) AUTO_START_CLUSTER="0"; shift ;;
    --keep-cluster-up) KEEP_CLUSTER_UP="1"; shift ;;
    --wait-timeout-seconds) WAIT_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --poll-interval-seconds) POLL_INTERVAL_SECONDS="$2"; shift 2 ;;
    --watch) WATCH="1"; shift ;;
    --watch-interval-seconds) WATCH_INTERVAL_SECONDS="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

local_runtime_pids() { pgrep -f 'mirror_neuron.*server' || true; }
remote_runtime_pids() { ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX pgrep -f 'mirror_neuron.*server' || true"; }

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

ensure_local_docker() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  if command -v open >/dev/null 2>&1; then
    echo "Starting Docker Desktop on box 1..."
    open -a Docker >/dev/null 2>&1 || true
  fi

  local attempt
  for attempt in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  echo "Docker is not ready on box 1. Verify Docker Desktop is running." >&2
  return 1
}

ensure_local_redis() {
  ensure_local_docker

  if docker inspect "$REDIS_CONTAINER_NAME" >/dev/null 2>&1; then
    local running
    running="$(docker inspect -f '{{.State.Running}}' "$REDIS_CONTAINER_NAME" 2>/dev/null || true)"
    if [ "$running" != "true" ]; then
      echo "Starting Redis container on box 1..."
      docker start "$REDIS_CONTAINER_NAME" >/dev/null
    fi
  else
    echo "Starting Redis container on box 1..."
    docker run -d --name "$REDIS_CONTAINER_NAME" -p 6379:6379 redis:7 >/dev/null
  fi

  local attempt
  for attempt in $(seq 1 30); do
    if docker exec "$REDIS_CONTAINER_NAME" redis-cli ping >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  echo "Redis is not ready on box 1." >&2
  return 1
}

cleanup_cluster_bootstrap() {
  if [ "$STARTED_CLUSTER" != "1" ] || [ "$KEEP_CLUSTER_UP" = "1" ]; then
    return
  fi

  echo "Cleaning up auto-started cluster runtimes..."
  stop_runtime_local
  stop_runtime_remote
}

if [ -n "$SELF_IP" ]; then
  ensure_local_redis
fi

trap cleanup_cluster_bootstrap EXIT

RUNNER=("$ROOT_DIR/mirror_neuron")

if [ -n "$BOX1_IP" ] || [ -n "$BOX2_IP" ] || [ -n "$SELF_IP" ]; then
  if [ -z "$BOX1_IP" ] || [ -z "$BOX2_IP" ] || [ -z "$SELF_IP" ]; then
    echo "cluster mode requires --box1-ip, --box2-ip, and --self-ip together" >&2
    exit 1
  fi

  RUNNER=(
    bash "$ROOT_DIR/scripts/cluster_cli.sh"
    --box1-ip "$BOX1_IP"
    --box2-ip "$BOX2_IP"
    --self-ip "$SELF_IP"
    --cookie "${MIRROR_NEURON_COOKIE:-mirrorneuron}"
    --
  )

  REDIS_URL="redis://${BOX1_IP}:6379/0"
fi

cluster_inspect_nodes() {
  bash "$ROOT_DIR/scripts/cluster_cli.sh" \
    --box1-ip "$BOX1_IP" \
    --box2-ip "$BOX2_IP" \
    --self-ip "$SELF_IP" \
    --cookie "${MIRROR_NEURON_COOKIE:-mirrorneuron}" \
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
  tail -n 40 "$LOCAL_CLUSTER_LOG" >&2 || true
  ssh "$BOX2_IP" "tail -n 40 '$REMOTE_CLUSTER_LOG'" >&2 || true
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

bootstrap_cluster_if_needed() {
  if [ -z "$SELF_IP" ]; then
    return
  fi

  local nodes
  nodes="$(cluster_inspect_nodes 2>/dev/null || true)"
  if printf '%s\n' "$nodes" | grep -q "mn1@$BOX1_IP" && printf '%s\n' "$nodes" | grep -q "mn2@$BOX2_IP"; then
    return
  fi

  if [ "$AUTO_START_CLUSTER" != "1" ]; then
    echo "no runtime nodes available in the connected cluster" >&2
    exit 1
  fi

  echo "No healthy cluster detected. Auto-starting two-box runtime..."
  ensure_local_redis
  echo "Syncing repo to box 2..."
  ssh "$BOX2_IP" "mkdir -p \"$REMOTE_ROOT\""
  rsync -az --delete \
    --exclude '.git/' \
    --exclude '_build/' \
    --exclude 'deps/' \
    --exclude 'var/' \
    "$ROOT_DIR/" "$BOX2_IP:$REMOTE_ROOT/"

  echo "Building box 1 runtime..."
  (cd "$ROOT_DIR" && mix escript.build >/dev/null)

  echo "Building box 2 runtime..."
  ssh "$BOX2_IP" "cd \"$REMOTE_ROOT\" && $REMOTE_PATH_PREFIX mix escript.build >/dev/null"

  stop_runtime_local
  stop_runtime_remote

  epmd -daemon
  ssh "$BOX2_IP" "$REMOTE_PATH_PREFIX epmd -daemon" >/dev/null 2>&1 || true

  echo "Starting box 1 runtime..."
  (
    cd "$ROOT_DIR"
    export ERL_AFLAGS="-kernel inet_dist_listen_min $DIST_PORT inet_dist_listen_max $DIST_PORT"
    export MIRROR_NEURON_NODE_NAME="mn1@$BOX1_IP"
    export MIRROR_NEURON_NODE_ROLE="runtime"
    export MIRROR_NEURON_COOKIE="$COOKIE"
    export MIRROR_NEURON_CLUSTER_NODES="mn1@$BOX1_IP,mn2@$BOX2_IP"
    export MIRROR_NEURON_REDIS_URL="redis://$BOX1_IP:6379/0"
    ./mirror_neuron server >"$LOCAL_CLUSTER_LOG" 2>&1 &
    echo $!
  )

  echo "Starting box 2 runtime..."
  ssh "$BOX2_IP" "cd \"$REMOTE_ROOT\" && $REMOTE_PATH_PREFIX export ERL_AFLAGS='-kernel inet_dist_listen_min $DIST_PORT inet_dist_listen_max $DIST_PORT'; export MIRROR_NEURON_NODE_NAME='mn2@$BOX2_IP'; export MIRROR_NEURON_NODE_ROLE='runtime'; export MIRROR_NEURON_COOKIE='$COOKIE'; export MIRROR_NEURON_CLUSTER_NODES='mn1@$BOX1_IP,mn2@$BOX2_IP'; export MIRROR_NEURON_REDIS_URL='redis://$BOX1_IP:6379/0'; nohup ./mirror_neuron server >'$REMOTE_CLUSTER_LOG' 2>&1 </dev/null & echo \$!"

  STARTED_CLUSTER="1"
  force_cluster_connect
  wait_for_cluster
}

BUNDLE_ARGS=(
  --animals "$ANIMALS"
  --regions "$REGIONS"
  --duration-seconds "$DURATION_SECONDS"
  --tick-seconds "$TICK_SECONDS"
  --max-food "$MAX_FOOD"
  --food-regen-per-tick "$FOOD_REGEN_PER_TICK"
  --max-region-population "$MAX_REGION_POPULATION"
  --migration-rate "$MIGRATION_RATE"
  --mutation-rate "$MUTATION_RATE"
)

if [ -z "$TICK_DELAY_MS" ] && [ "$WATCH" = "1" ]; then
  TICK_DELAY_MS="120"
fi

if [ -n "$SEED" ]; then
  BUNDLE_ARGS+=(--seed "$SEED")
fi

if [ -n "$TICK_DELAY_MS" ]; then
  BUNDLE_ARGS+=(--tick-delay-ms "$TICK_DELAY_MS")
fi

if [ "$DRY_RUN" = "1" ] || [ -n "$SELF_IP" ]; then
  TMP_OUTPUT_DIR="$(mktemp -d /tmp/mirror_neuron_ecosystem.XXXXXX)"
  if [ -n "$SELF_IP" ]; then
    TMP_OUTPUT_DIR="$BUNDLE_ROOT"
    mkdir -p "$TMP_OUTPUT_DIR"
  fi
  BUNDLE_ARGS+=(--output-dir "$TMP_OUTPUT_DIR")
fi

BUNDLE_PATH="$(python3 "$SCRIPT_DIR/generate_bundle.py" "${BUNDLE_ARGS[@]}")"
RESULT_PATH="$BUNDLE_PATH/result.json"

if [ -z "$SELF_IP" ]; then
  ensure_local_redis
  echo "Building MirrorNeuron runtime..."
  (cd "$ROOT_DIR" && mix escript.build >/dev/null)
else
  bootstrap_cluster_if_needed
fi

echo "Generated bundle:"
echo "  $BUNDLE_PATH"
if [ -z "$SEED" ]; then
  SEED="$(python3 - "$BUNDLE_PATH/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
for node in manifest["nodes"]:
    if node["node_id"] == "world":
        print(node["config"]["seed"])
        break
PY
)"
fi
echo "Simulation seed:"
echo "  $SEED"

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run only. Bundle path:"
  echo "  $BUNDLE_PATH"
  exit 0
fi

if [ -n "$SELF_IP" ]; then
  if [ "$SELF_IP" = "$BOX1_IP" ]; then
    PEER_IP="$BOX2_IP"
  else
    PEER_IP="$BOX1_IP"
  fi
  echo "Syncing bundle to peer box:"
  echo "  peer=$PEER_IP"
  ssh "$PEER_IP" "mkdir -p \"$(dirname "$BUNDLE_PATH")\" && rm -rf \"$BUNDLE_PATH\""
  scp -r "$BUNDLE_PATH" "${PEER_IP}:$(dirname "$BUNDLE_PATH")/" >/dev/null
fi

echo "Validating bundle..."
"${RUNNER[@]}" validate "$BUNDLE_PATH" >/dev/null

echo "Running ecosystem simulation..."
echo "  timeout: ${WAIT_TIMEOUT_SECONDS}s"
echo "  poll interval: ${POLL_INTERVAL_SECONDS}s"

wait_for_terminal_job_json() {
  local job_id="$1"

  cd "$ROOT_DIR"
  env MIRROR_NEURON_REDIS_URL="$REDIS_URL" mix run --no-start -e '
    Application.ensure_all_started(:mirror_neuron)
    job_id = System.argv() |> Enum.at(0)
    timeout_seconds = System.argv() |> Enum.at(1) |> String.to_integer()
    poll_interval_ms = System.argv() |> Enum.at(2) |> String.to_integer() |> Kernel.*(1_000)
    deadline = System.monotonic_time(:millisecond) + timeout_seconds * 1_000

    wait = fn wait ->
      case MirrorNeuron.inspect_job(job_id) do
        {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
          IO.puts(Jason.encode!(%{
            ok: true,
            status: job["status"],
            result: job["result"],
            job_id: job_id
          }))

        _ ->
          progress =
            case MirrorNeuron.inspect_agents(job_id) do
              {:ok, agents} ->
                regions = Enum.filter(agents, &String.starts_with?(&1["agent_id"] || "", "region_"))
                progressed =
                  Enum.count(regions, fn agent ->
                    tick = get_in(agent, ["current_state", "agent_state", "tick"]) || 0
                    tick > 0
                  end)
                "progress regions=#{progressed}/#{length(regions)}"

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
  ' -- "$job_id" "$WAIT_TIMEOUT_SECONDS" "$POLL_INTERVAL_SECONDS"
}

run_ascii_watch() {
  local job_id="$1"
  local watch_args=("$job_id" "--interval" "$WATCH_INTERVAL_SECONDS")

  if [ -n "$SELF_IP" ]; then
    watch_args+=("--box1-ip" "$BOX1_IP")
  fi

  (
    cd "$ROOT_DIR" &&
      env MIRROR_NEURON_REDIS_URL="$REDIS_URL" \
        mix run --no-start examples/ecosystem_simulation/watch_ascii.exs -- "${watch_args[@]}"
  )
}

if [ -z "$SELF_IP" ]; then
  if [ "$WATCH" = "1" ]; then
    SUBMIT_JOB_ID_FILE="$(mktemp /tmp/mirror_neuron_ecosystem_jobid.XXXXXX)"
    SUBMIT_RESULT_FILE="$(mktemp /tmp/mirror_neuron_ecosystem_result.XXXXXX)"

    (
      cd "$ROOT_DIR"
      env MIRROR_NEURON_REDIS_URL="$REDIS_URL" mix run --no-start -e '
        Application.ensure_all_started(:mirror_neuron)
        bundle_path = Enum.at(System.argv(), 0)
        job_id_file = Enum.at(System.argv(), 1)
        timeout_ms = Enum.at(System.argv(), 2) |> String.to_integer() |> Kernel.*(1_000)
        start_result =
          case MirrorNeuron.run_manifest(bundle_path, await: false) do
            {:ok, id} -> {:ok, id}
            {:ok, id, _job} -> {:ok, id}
            other -> other
          end

        with {:ok, job_id} <- start_result do
          File.write!(job_id_file, job_id)

          case MirrorNeuron.wait_for_job(job_id, timeout_ms) do
            {:ok, job} ->
              IO.puts(Jason.encode!(%{
                ok: true,
                status: job["status"],
                result: job["result"],
                job_id: job_id
              }))

            {:error, reason} ->
              IO.puts(Jason.encode!(%{
                ok: false,
                status: "failed",
                result: %{"error" => to_string(reason)},
                job_id: job_id
              }))
              System.halt(1)
          end
        else
          {:error, reason} ->
            IO.puts(:stderr, "failed to start ecosystem simulation: #{inspect(reason)}")
            System.halt(1)
        end
      ' -- "$BUNDLE_PATH" "$SUBMIT_JOB_ID_FILE" "$WAIT_TIMEOUT_SECONDS" >"$SUBMIT_RESULT_FILE"
    ) &
    SUBMIT_PID=$!

    for _ in $(seq 1 200); do
      if [ -s "$SUBMIT_JOB_ID_FILE" ]; then
        break
      fi
      sleep 0.1
    done

    if [ ! -s "$SUBMIT_JOB_ID_FILE" ]; then
      kill "$SUBMIT_PID" >/dev/null 2>&1 || true
      echo "failed to obtain job id for watch mode" >&2
      exit 1
    fi

    JOB_ID="$(cat "$SUBMIT_JOB_ID_FILE")"
    echo "Submitted job:"
    echo "  $JOB_ID"
    echo "Launching ASCII watcher..."
    run_ascii_watch "$JOB_ID"
    wait "$SUBMIT_PID"
    cp "$SUBMIT_RESULT_FILE" "$RESULT_PATH"
  else
    time "${RUNNER[@]}" run "$BUNDLE_PATH" --json | tee "$RESULT_PATH"
  fi
else
  SUBMIT_OUTPUT_FILE="$(mktemp /tmp/mirror_neuron_ecosystem_submit.XXXXXX)"
  time "${RUNNER[@]}" run "$BUNDLE_PATH" --json --no-await >"$SUBMIT_OUTPUT_FILE"

  JOB_ID="$(
    python3 - "$SUBMIT_OUTPUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text()
decoder = json.JSONDecoder()
for index, char in enumerate(raw):
    if char != "{":
        continue
    try:
        payload, _ = decoder.raw_decode(raw[index:])
        if "job_id" in payload:
            print(payload["job_id"])
            break
    except json.JSONDecodeError:
        continue
else:
    raise SystemExit("could not decode submit JSON")
PY
  )"

  echo "Submitted job:"
  echo "  $JOB_ID"
  if [ "$WATCH" = "1" ]; then
    echo "Launching ASCII watcher..."
    run_ascii_watch "$JOB_ID"
  else
    echo "Waiting for completion..."
  fi

  JOB_JSON="$(wait_for_terminal_job_json "$JOB_ID")"

  printf '%s\n' "$JOB_JSON" >"$RESULT_PATH"
fi

echo "Result written to:"
echo "  $RESULT_PATH"
echo "Summary:"
python3 "$SCRIPT_DIR/summarize_result.py" "$RESULT_PATH"
echo ""
python3 "$SCRIPT_DIR/summarize_result.py" "$RESULT_PATH" --chart-only
