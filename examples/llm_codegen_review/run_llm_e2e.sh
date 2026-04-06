#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/examples/llm_codegen_review"
MODEL="${MIRROR_NEURON_GEMINI_MODEL:-gemini-2.5-flash-lite}"
DRY_RUN="0"
BOX1_IP=""
BOX2_IP=""
SELF_IP=""
WAIT_TIMEOUT_SECONDS="${MIRROR_NEURON_LLM_WAIT_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${MIRROR_NEURON_LLM_POLL_INTERVAL_SECONDS:-5}"
REDIS_URL="${MIRROR_NEURON_REDIS_URL:-redis://127.0.0.1:6379/0}"

usage() {
  cat <<'EOF'
usage:
  bash examples/llm_codegen_review/run_llm_e2e.sh [options]

examples:
  bash examples/llm_codegen_review/run_llm_e2e.sh
  bash examples/llm_codegen_review/run_llm_e2e.sh --box1-ip 192.168.4.29 --box2-ip 192.168.4.35 --self-ip 192.168.4.29

options:
      --model <name>            Gemini model to use, defaults to gemini-2.5-flash-lite
      --box1-ip <ip>            Submit through cluster_cli.sh using box 1
      --box2-ip <ip>            Submit through cluster_cli.sh using box 2
      --self-ip <ip>            Submit through cluster_cli.sh from this machine
      --wait-timeout-seconds <n>
                                Maximum time to wait for completion, defaults to 300
      --poll-interval-seconds <n>
                                Progress poll interval while waiting, defaults to 5
      --dry-run                 Generate only; do not run
  -h, --help                    Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      MODEL="$2"
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
    --wait-timeout-seconds)
      WAIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --poll-interval-seconds)
      POLL_INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
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

if [ -z "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ]; then
  echo "GEMINI_API_KEY or GOOGLE_API_KEY must be set before running this e2e test." >&2
  exit 1
fi

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

BUNDLE_ARGS=(--model "$MODEL")

if [ "$DRY_RUN" = "1" ]; then
  TMP_OUTPUT_DIR="$(mktemp -d /tmp/mirror_neuron_llm_codegen.XXXXXX)"
  BUNDLE_ARGS+=(--output-dir "$TMP_OUTPUT_DIR")
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

echo "Running LLM codegen/review loop..."
echo "  timeout: ${WAIT_TIMEOUT_SECONDS}s"
echo "  poll interval: ${POLL_INTERVAL_SECONDS}s"

if [ -z "$SELF_IP" ]; then
  time "${RUNNER[@]}" run "$BUNDLE_PATH" --json | tee "$RESULT_PATH"
else
  SUBMIT_JSON="$(
    time "${RUNNER[@]}" run "$BUNDLE_PATH" --json --no-await
  )"

  JOB_ID="$(
    printf '%s\n' "$SUBMIT_JSON" \
      | python3 -c '
import json, sys
raw = sys.stdin.read()
decoder = json.JSONDecoder()
for index, char in enumerate(raw):
    if char != "{":
        continue
    try:
        payload, _ = decoder.raw_decode(raw[index:])
        print(payload["job_id"])
        break
    except json.JSONDecodeError:
        continue
else:
    raise SystemExit("could not decode submit JSON")
'
  )"

  echo "Submitted job:"
  echo "  $JOB_ID"
  echo "Waiting for completion..."

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
                  execs = Enum.filter(agents, &(&1["agent_type"] == "executor"))
                  done = Enum.count(execs, &(get_in(&1, ["current_state", "runs"]) == 1))
                  "progress executors=#{done}/#{length(execs)}"

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
fi

echo "Result written to:"
echo "  $RESULT_PATH"
echo "Summary:"
python3 "$SCRIPT_DIR/summarize_result.py" "$RESULT_PATH"
