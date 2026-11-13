defmodule MirrorNeuron.Runtime.JobResponse.Warmup do
  @moduledoc "Applies preparation results and schedules bounded recovery backoff."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobResponse.Status

  @max_retry_ms 30_000

  def apply_warm_result(result, started, state) do
    case result do
      {:ok, result} ->
        service_state = Status.normalize_state(result["state"], "ready")
        now = Runtime.timestamp()
        latency = System.monotonic_time(:millisecond) - started
        Status.log_event(state.definition["job_id"], "warm", service_state, latency)

        next = %{
          state
          | state: service_state,
            ready_at: if(service_state in ["ready", "degraded"], do: now, else: state.ready_at),
            updated_at: now,
            safe_error_code: nil,
            retry_ms: if(service_state == "degraded", do: state.retry_ms, else: 1_000)
        }

        {:noreply,
         if(service_state in ["starting", "degraded", "failed"],
           do: schedule_warm_retry(next),
           else: next
         )}

      {:error, reason} ->
        code = Status.safe_error_code(reason)
        Status.log_event(state.definition["job_id"], "warm", "failed", nil, code)

        {:noreply,
         schedule_warm_retry(%{
           state
           | state: "failed",
             updated_at: Runtime.timestamp(),
             safe_error_code: code
         })}
    end
  end

  def schedule_warm_retry(%{warm_timer: nil} = state) do
    %{
      state
      | warm_timer: Process.send_after(self(), :warm, state.retry_ms),
        retry_ms: min(state.retry_ms * 2, @max_retry_ms)
    }
  end

  def schedule_warm_retry(state), do: state

  def start_payload(definition) do
    %{
      "kind" => "job_response",
      "operation" => "start",
      "async" => true,
      "job_id" => definition["job_id"],
      "blueprint_id" => definition["blueprint_id"],
      "job_data_dir" => definition["data_dir"],
      "manifest" => definition["manifest"] || %{},
      "configuration" => definition["resolved_configuration"] || %{},
      "revision" => definition["revision"]
    }
  end
end
