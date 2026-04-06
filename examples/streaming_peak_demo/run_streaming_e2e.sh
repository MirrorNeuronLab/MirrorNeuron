#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/examples/streaming_peak_demo"
SAMPLE_COUNT="60"
CHUNK_SIZE="6"
BASELINE="24"
JITTER="4"
PEAK_HEIGHT="55"
PEAK_POSITIONS=""
CONTENT_ENCODING="gzip"
WAIT_TIMEOUT_SECONDS="${MIRROR_NEURON_STREAM_WAIT_TIMEOUT_SECONDS:-120}"
POLL_INTERVAL_SECONDS="${MIRROR_NEURON_STREAM_POLL_INTERVAL_SECONDS:-3}"
BOX1_IP=""
BOX2_IP=""
SELF_IP=""
DRY_RUN="0"
REDIS_URL="${MIRROR_NEURON_REDIS_URL:-redis://127.0.0.1:6379/0}"
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
usage:
  bash examples/streaming_peak_demo/run_streaming_e2e.sh [options]

examples:
  bash examples/streaming_peak_demo/run_streaming_e2e.sh
  bash examples/streaming_peak_demo/run_streaming_e2e.sh --sample-count 72 --chunk-size 8
  bash examples/streaming_peak_demo/run_streaming_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29

options:
      --sample-count <n>        Number of telemetry samples, defaults to 60
      --chunk-size <n>          Samples per stream chunk, defaults to 6
      --baseline <n>            Baseline value, defaults to 24
      --jitter <n>              Baseline jitter, defaults to 4
      --peak-height <n>         Added value for anomaly spikes, defaults to 55
      --peak-positions <list>   Comma-separated 1-based peak positions
      --content-encoding <enc>  gzip or identity, defaults to gzip
      --wait-timeout-seconds <n>
                                Maximum time to wait for completion, defaults to 120
      --poll-interval-seconds <n>
                                Poll interval while waiting, defaults to 3
      --box1-ip <ip>            Submit through cluster_cli.sh using box 1
      --box2-ip <ip>            Submit through cluster_cli.sh using box 2
      --self-ip <ip>            Submit through cluster_cli.sh from this machine
      --dry-run                 Generate only; do not run
      --output-dir <path>       Override generator output directory
  -h, --help                    Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sample-count)
      SAMPLE_COUNT="$2"
      shift 2
      ;;
    --chunk-size)
      CHUNK_SIZE="$2"
      shift 2
      ;;
    --baseline)
      BASELINE="$2"
      shift 2
      ;;
    --jitter)
      JITTER="$2"
      shift 2
      ;;
    --peak-height)
      PEAK_HEIGHT="$2"
      shift 2
      ;;
    --peak-positions)
      PEAK_POSITIONS="$2"
      shift 2
      ;;
    --content-encoding)
      CONTENT_ENCODING="$2"
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
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
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
    --
  )

  REDIS_URL="redis://${BOX1_IP}:6379/0"
fi

BUNDLE_ARGS=(
  --sample-count "$SAMPLE_COUNT"
  --chunk-size "$CHUNK_SIZE"
  --baseline "$BASELINE"
  --jitter "$JITTER"
  --peak-height "$PEAK_HEIGHT"
  --content-encoding "$CONTENT_ENCODING"
)

if [ -n "$PEAK_POSITIONS" ]; then
  BUNDLE_ARGS+=(--peak-positions "$PEAK_POSITIONS")
fi

if [ "$DRY_RUN" = "1" ]; then
  TMP_OUTPUT_DIR="$(mktemp -d /tmp/mirror_neuron_streaming_demo.XXXXXX)"
  OUTPUT_DIR="$TMP_OUTPUT_DIR"
fi

if [ -n "$OUTPUT_DIR" ]; then
  BUNDLE_ARGS+=(--output-dir "$OUTPUT_DIR")
fi

BUNDLE_PATH="$(python3 "$SCRIPT_DIR/generate_bundle.py" "${BUNDLE_ARGS[@]}")"
RESULT_PATH="$BUNDLE_PATH/result.json"

echo "Generated bundle:"
echo "  $BUNDLE_PATH"

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run only. Bundle path:"
  echo "  $BUNDLE_PATH"
  exit 0
fi

if [ -n "$SELF_IP" ] && [ -n "$BOX2_IP" ]; then
  echo "Syncing bundle to peer box:"
  echo "  peer=$BOX2_IP"
  ssh "$BOX2_IP" "mkdir -p \"$(dirname "$BUNDLE_PATH")\" && rm -rf \"$BUNDLE_PATH\""
  scp -r "$BUNDLE_PATH" "${BOX2_IP}:$(dirname "$BUNDLE_PATH")/" >/dev/null
fi

echo "Validating bundle..."
"${RUNNER[@]}" validate "$BUNDLE_PATH" >/dev/null

echo "Running streaming peak demo..."
echo "  timeout: ${WAIT_TIMEOUT_SECONDS}s"
echo "  poll interval: ${POLL_INTERVAL_SECONDS}s"

if [ -z "$SELF_IP" ]; then
  time "${RUNNER[@]}" run "$BUNDLE_PATH" --json | tee "$RESULT_PATH"
else
  SUBMIT_JSON_FILE="$(mktemp /tmp/mirror_neuron_stream_submit.XXXXXX.json)"
  trap 'rm -f "$SUBMIT_JSON_FILE"' EXIT

  "${RUNNER[@]}" run "$BUNDLE_PATH" --json --no-await >"$SUBMIT_JSON_FILE"

  JOB_ID="$(
    python3 - "$SUBMIT_JSON_FILE" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text().strip()
if not raw:
    raise SystemExit("submission did not return JSON")

decoder = json.JSONDecoder()

for index, character in enumerate(raw):
    if character != "{":
        continue
    try:
        payload, end_index = decoder.raw_decode(raw[index:])
    except json.JSONDecodeError:
        continue
    if "job_id" in payload:
        print(payload["job_id"])
        raise SystemExit(0)

raise SystemExit("could not decode job id from submission output")
PY
  )"

  if [ -z "$JOB_ID" ]; then
    echo "failed to decode job id from cluster submission output" >&2
    exit 1
  fi

  JOB_JSON="$(
    cd "$ROOT_DIR"
    env \
      MIRROR_NEURON_REDIS_URL="$REDIS_URL" \
      mix run --no-start -e '
      Application.ensure_all_started(:mirror_neuron)
      job_id = System.argv() |> List.first()
      timeout_seconds = System.argv() |> Enum.at(1) |> String.to_integer()
      poll_interval_ms = System.argv() |> Enum.at(2) |> String.to_integer() |> Kernel.*(1_000)
      deadline = System.monotonic_time(:millisecond) + timeout_seconds * 1_000

      wait = fn wait ->
        case MirrorNeuron.inspect_job(job_id) do
          {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
            IO.puts(Jason.encode!(job))

          _ ->
            progress =
              case MirrorNeuron.inspect_agents(job_id) do
                {:ok, agents} ->
                  detector = Enum.find(agents, &(&1["agent_id"] == "peak_detector"))
                  points =
                    get_in(detector || %{}, ["current_state", "agent_state", "points_seen"]) ||
                      get_in(detector || %{}, ["current_state", "points_seen"]) || 0

                  chunks =
                    get_in(detector || %{}, ["current_state", "agent_state", "chunks_received"]) ||
                      get_in(detector || %{}, ["current_state", "chunks_received"]) || 0

                  "progress chunks=#{chunks} points=#{points}"

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
  rm -f "$SUBMIT_JSON_FILE"
  trap - EXIT
  echo "Submitted job:"
  echo "  $JOB_ID"
  echo "Waiting for completion..."
fi

echo "Result written to:"
echo "  $RESULT_PATH"
echo "Summary:"
python3 "$SCRIPT_DIR/summarize_result.py" "$RESULT_PATH"

JOB_ID="$(
  python3 - "$RESULT_PATH" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text()
decoder = json.JSONDecoder()

for index, character in enumerate(raw):
    if character != "{":
        continue
    try:
        payload, end_index = decoder.raw_decode(raw[index:])
    except json.JSONDecodeError:
        continue
    if not raw[index + end_index :].strip():
        print(payload["job_id"])
        raise SystemExit(0)

raise SystemExit("could not decode job id from result file")
PY
)"

echo "Agent placement:"
cd "$ROOT_DIR"
env MIRROR_NEURON_REDIS_URL="$REDIS_URL" mix run --no-start -e '
Application.ensure_all_started(:mirror_neuron)
job_id = System.argv() |> List.first()

case MirrorNeuron.inspect_agents(job_id) do
  {:ok, agents} ->
    agents
    |> Enum.group_by(& &1["assigned_node"])
    |> Enum.sort_by(fn {node, _agents} -> node end)
    |> Enum.each(fn {node, node_agents} ->
      names =
        node_agents
        |> Enum.map(& &1["agent_id"])
        |> Enum.sort()
        |> Enum.join(", ")

      IO.puts("  #{node}: #{names}")
    end)

  {:error, reason} ->
    IO.puts("  unavailable: #{inspect(reason)}")
end
' -- "$JOB_ID"
