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
       agent_state: %{},
       last_output_payload: nil,
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

    case run_with_retry(payload, state, context, normalized_message) do
      {:ok, result, attempts} ->
        output_payload = %{
          "agent_id" => context.node.node_id,
          "sandbox" => Map.merge(result, %{"attempts" => attempts, "lease" => lease}),
          "input" => payload
        }

        {structured_state, structured_actions} =
          structured_actions(result, state, normalized_message, output_payload)

        actions =
          [
            {:event, :sandbox_job_completed,
             %{
               "sandbox_name" => result["sandbox_name"],
               "exit_code" => result["exit_code"],
               "attempts" => attempts,
               "lease_id" => lease["lease_id"],
               "pool" => lease["pool"]
             }}
          ] ++ default_output_actions(state.config, output_payload) ++ structured_actions

        {:ok,
         %{
           state
           | runs: state.runs + 1,
             agent_state: structured_state,
             last_output_payload: output_payload,
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

  @impl true
  def recover(%{last_output_payload: payload} = state, _context) when is_map(payload) do
    actions =
      [
        {:event, :executor_output_replayed,
         %{
           "reason" => "agent_recovery",
           "agent_id" => payload["agent_id"]
         }}
      ] ++ default_output_actions(state.config, payload)

    {:ok, state, actions}
  end

  def recover(state, _context), do: {:ok, state, []}

  defp default_output_actions(config, payload) do
    output_actions =
      case Map.fetch(config, "output_message_type") do
        {:ok, nil} ->
          []

        {:ok, output_message_type} ->
          [
            {:emit, output_message_type, payload,
             [
               class: "event",
               headers: %{
                 "schema_ref" => "com.mirrorneuron.executor.result",
                 "schema_version" => "1.0.0"
               }
             ]}
          ]

        :error ->
          [
            {:emit, "executor_result", payload,
             [
               class: "event",
               headers: %{
                 "schema_ref" => "com.mirrorneuron.executor.result",
                 "schema_version" => "1.0.0"
               }
             ]}
          ]
      end

    output_actions ++ maybe_complete(config, payload)
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

  defp run_with_retry(payload, state, context, message),
    do: run_with_retry(payload, state, context, message, 1)

  defp run_with_retry(payload, state, context, message, attempt) do
    config = state.config
    runner = resolve_runner(config)

    case runner.run(
           payload,
           config,
           message: message,
           attempt: attempt,
           job_id: context.job_id,
           agent_id: context.node.node_id,
           agent_type: Map.get(context.node, :agent_type),
           template_type: Map.get(context.node, :type, "generic"),
           agent_state: state.agent_state,
           bundle_root: context.bundle_root,
           manifest_path: context.manifest_path,
           payloads_path: context.payloads_path
         ) do
      {:ok, result} ->
        {:ok, result, attempt}

      {:error, reason} ->
        if retryable?(reason) and attempt < max_attempts(config) do
          Process.sleep(backoff_ms(config, attempt))
          run_with_retry(payload, state, context, message, attempt + 1)
        else
          {:error, reason, attempt}
        end
    end
  end

  defp structured_actions(result, state, incoming, default_payload) do
    case decode_structured_stdout(result) do
      nil ->
        {state.agent_state, []}

      payload ->
        next_state = Map.get(payload, "next_state", state.agent_state)

        actions =
          structured_event_actions(payload) ++
            structured_emit_actions(payload, incoming) ++
            structured_completion_actions(payload, default_payload)

        {next_state, actions}
    end
  end

  defp structured_event_actions(payload) do
    payload
    |> Map.get("events", [])
    |> Enum.flat_map(fn
      %{"type" => type, "payload" => event_payload}
      when is_binary(type) and is_map(event_payload) ->
        [{:event, String.to_atom(type), event_payload}]

      _ ->
        []
    end)
  end

  defp structured_emit_actions(payload, incoming) do
    payload
    |> Map.get("emit_messages", [])
    |> Enum.flat_map(fn item ->
      emit_action(item, incoming)
    end)
  end

  defp emit_action(
         %{"to" => to_node, "type" => message_type} = item,
         incoming
       )
       when is_binary(to_node) and is_binary(message_type) do
    [
      {:emit_to, to_node, message_type, message_body(item), emit_opts(item, incoming)}
    ]
  end

  defp emit_action(%{"type" => message_type} = item, incoming) when is_binary(message_type) do
    [
      {:emit, message_type, message_body(item), emit_opts(item, incoming)}
    ]
  end

  defp emit_action(_item, _incoming), do: []

  defp message_body(item) do
    cond do
      Map.has_key?(item, "body_base64") ->
        item["body_base64"] |> Base.decode64!()

      Map.has_key?(item, "body") ->
        item["body"]

      Map.has_key?(item, "payload") ->
        item["payload"]

      true ->
        %{}
    end
  end

  defp emit_opts(item, incoming) do
    []
    |> maybe_put_opt(:class, Map.get(item, "class"))
    |> maybe_put_opt(
      :correlation_id,
      Map.get(item, "correlation_id", Message.correlation_id(incoming))
    )
    |> maybe_put_opt(:causation_id, Map.get(item, "causation_id", Message.id(incoming)))
    |> maybe_put_opt(:content_type, Map.get(item, "content_type", Message.content_type(incoming)))
    |> maybe_put_opt(
      :content_encoding,
      Map.get(item, "content_encoding", Message.content_encoding(incoming))
    )
    |> maybe_put_opt(:headers, Map.get(item, "headers", %{}))
    |> maybe_put_opt(:artifacts, Map.get(item, "artifacts", Message.artifacts(incoming)))
    |> maybe_put_opt(:stream, Map.get(item, "stream"))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp structured_completion_actions(payload, default_payload) do
    cond do
      Map.get(payload, "complete_job") != nil ->
        [{:complete_job, payload["complete_job"]}]

      Map.get(payload, "complete_job?", false) ->
        [{:complete_job, default_payload}]

      true ->
        []
    end
  end

  defp decode_structured_stdout(result) do
    with stdout when is_binary(stdout) and stdout != "" <- Map.get(result, "stdout"),
         {:ok, decoded} <- Jason.decode(stdout),
         true <- structured_payload?(decoded) do
      decoded
    else
      _ -> nil
    end
  end

  defp structured_payload?(decoded) when is_map(decoded) do
    Enum.any?(
      ["emit_messages", "events", "next_state", "complete_job", "complete_job?"],
      &Map.has_key?(decoded, &1)
    )
  end

  defp structured_payload?(_decoded), do: false

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

  defp resolve_runner(config) do
    case Map.get(config, "runner_module") || Map.get(config, :runner_module) do
      nil ->
        OpenShell

      module when is_atom(module) ->
        module

      module_name when is_binary(module_name) ->
        module_name
        |> String.split(".", trim: true)
        |> Enum.map(&String.to_atom/1)
        |> Module.concat()
    end
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
