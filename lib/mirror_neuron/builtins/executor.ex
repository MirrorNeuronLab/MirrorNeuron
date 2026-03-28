defmodule MirrorNeuron.Builtins.Executor do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Message
  alias MirrorNeuron.Sandbox.OpenShell

  @transient_markers [
    "h2 protocol error",
    "peer closed connection",
    "status: Unknown",
    "error reading a body from connection",
    "TLS close_notify",
    "transport error",
    "connection reset",
    "connection refused",
    "timed out",
    "deadline exceeded",
    "unavailable"
  ]

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config,
       runs: 0,
       last_result: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    normalized_message =
      Message.normalize!(message, job_id: context.job_id, to: context.node.node_id)

    payload = Message.body(normalized_message) || %{}
    pool = configured_pool(state.config)
    pool_slots = configured_pool_slots(state.config)
    lease_manager = configured_lease_manager(state.config)

    maybe_sleep_startup_delay(state)

    report_event(context, :executor_lease_requested, %{
      "pool" => pool,
      "slots" => pool_slots
    })

    with {:ok, lease} <-
           LeaseManager.acquire(lease_manager, pool, pool_slots, lease_metadata(context)) do
      run_under_lease(payload, state, context, normalized_message, lease, lease_manager)
    else
      {:error, reason} ->
        {:error, %{"error" => reason},
         %{state | runs: state.runs + 1, last_error: inspect(reason)}}
    end
  end

  defp run_under_lease(payload, state, context, normalized_message, lease, lease_manager) do
    report_event(context, :executor_lease_acquired, %{
      "lease_id" => lease["lease_id"],
      "pool" => lease["pool"],
      "slots" => lease["slots"],
      "queue_wait_ms" => lease["queue_wait_ms"]
    })

    case run_with_retry(payload, state.config, context, normalized_message) do
      {:ok, result, attempts} ->
        output_message_type = Map.get(state.config, "output_message_type", "executor_result")

        output_payload = %{
          "agent_id" => context.node.node_id,
          "sandbox" => Map.merge(result, %{"attempts" => attempts, "lease" => lease}),
          "input" => payload
        }

        actions =
          [
            {:event, :sandbox_job_completed,
             %{
               "sandbox_name" => result["sandbox_name"],
               "exit_code" => result["exit_code"],
               "attempts" => attempts,
               "lease_id" => lease["lease_id"],
               "pool" => lease["pool"]
             }},
            {:emit, output_message_type, output_payload,
             [
               class: "event",
               headers: %{
                 "schema_ref" => "com.mirrorneuron.executor.result",
                 "schema_version" => "1.0.0"
               }
             ]}
          ] ++ maybe_complete(state.config, output_payload)

        {:ok,
         %{
           state
           | runs: state.runs + 1,
             last_result: Map.put(Map.put(result, "attempts", attempts), "lease", lease),
             last_error: nil
         }, actions}

      {:error, reason, attempts} ->
        {:error, enrich_error(reason, attempts),
         %{state | runs: state.runs + 1, last_error: inspect(enrich_error(reason, attempts))}}
    end
  after
    LeaseManager.release(lease_manager, lease["lease_id"])

    report_event(context, :executor_lease_released, %{
      "lease_id" => lease["lease_id"],
      "pool" => lease["pool"],
      "slots" => lease["slots"]
    })
  end

  defp maybe_complete(config, payload) do
    if Map.get(config, "complete_job", false) do
      [{:complete_job, payload}]
    else
      []
    end
  end

  defp maybe_sleep_startup_delay(%{runs: 0, config: config}) do
    case Map.get(config, "startup_delay_ms", 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  defp maybe_sleep_startup_delay(_state), do: :ok

  defp run_with_retry(payload, config, context, message),
    do: run_with_retry(payload, config, context, message, 1)

  defp run_with_retry(payload, config, context, message, attempt) do
    runner = Map.get(config, "runner_module") || Map.get(config, :runner_module) || OpenShell

    case runner.run(
           payload,
           config,
           message: message,
           attempt: attempt,
           job_id: context.job_id,
           agent_id: context.node.node_id,
           bundle_root: context.bundle_root,
           manifest_path: context.manifest_path,
           payloads_path: context.payloads_path
         ) do
      {:ok, result} ->
        {:ok, result, attempt}

      {:error, reason} ->
        if retryable?(reason) and attempt < max_attempts(config) do
          Process.sleep(backoff_ms(config, attempt))
          run_with_retry(payload, config, context, message, attempt + 1)
        else
          {:error, reason, attempt}
        end
    end
  end

  defp max_attempts(config) do
    case Map.get(config, "max_attempts", 1) do
      attempts when is_integer(attempts) and attempts >= 1 -> attempts
      _ -> 1
    end
  end

  defp backoff_ms(config, attempt) do
    base =
      case Map.get(config, "retry_backoff_ms", 500) do
        delay when is_integer(delay) and delay >= 0 -> delay
        _ -> 500
      end

    trunc(base * :math.pow(2, max(attempt - 1, 0)))
  end

  defp retryable?(reason) do
    reason
    |> error_blob()
    |> String.downcase()
    |> then(fn blob ->
      Enum.any?(@transient_markers, &String.contains?(blob, String.downcase(&1)))
    end)
  end

  defp error_blob(reason) when is_map(reason) do
    [
      Map.get(reason, "error"),
      Map.get(reason, "logs"),
      Map.get(reason, "raw_output"),
      Map.get(reason, "stderr"),
      Map.get(reason, "stdout"),
      inspect(reason)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp error_blob(reason), do: inspect(reason)

  defp enrich_error(reason, attempts) when is_map(reason),
    do: Map.put(reason, "attempts", attempts)

  defp enrich_error(reason, attempts), do: %{"error" => inspect(reason), "attempts" => attempts}

  defp configured_pool(config) do
    config
    |> Map.get("pool", "default")
    |> to_string()
  end

  defp configured_pool_slots(config) do
    case Map.get(config, "pool_slots", 1) do
      slots when is_integer(slots) and slots > 0 -> slots
      _ -> 1
    end
  end

  defp configured_lease_manager(config) do
    Map.get(config, "lease_manager") || Map.get(config, :lease_manager) || LeaseManager
  end

  defp lease_metadata(context) do
    %{
      job_id: context.job_id,
      agent_id: context.node.node_id,
      node: to_string(Node.self())
    }
  end

  defp report_event(context, event_type, payload) do
    send(context.coordinator, {:agent_event, context.node.node_id, event_type, payload})
  end
end
