defmodule MirrorNeuron.Builtins.Executor do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.OpenShell

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
    "agent beacon deadline exceeded",
    "deadline exceeded",
    "unavailable"
  ]

  @impl true
  def init(node) do
    {:ok,
     %{
       config: Profile.apply_to_config(node.config),
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
    lease_opts = configured_lease_opts(state.config)

    maybe_sleep_startup_delay(state)

    report_event(context, :executor_lease_requested, %{
      "pool" => pool,
      "slots" => pool_slots
    })

    with {:ok, lease} <-
           LeaseManager.acquire(
             lease_manager,
             pool,
             pool_slots,
             lease_metadata(context),
             lease_opts
           ) do
      run_under_lease(payload, state, context, normalized_message, lease, lease_manager)
    else
      {:error, {:retry_later, details}} ->
        report_event(context, :executor_lease_rejected, details)

        {:error, details, %{state | runs: state.runs + 1, last_error: inspect(details)}}

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

        case structured_actions(result, state, normalized_message, output_payload) do
          {:ok, structured_state, structured_actions} ->
            {structured_output_actions, structured_control_actions} =
              Enum.split_with(structured_actions, &output_action?/1)

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
              ] ++
                structured_control_actions ++
                implicit_workflow_step_completion_actions(
                  context,
                  output_payload,
                  structured_actions
                ) ++
                default_output_actions(state.config, output_payload) ++
                structured_output_actions

            {:ok,
             %{
               state
               | runs: state.runs + 1,
                 agent_state: structured_state,
                 last_output_payload: output_payload,
                 last_result: Map.put(Map.put(result, "attempts", attempts), "lease", lease),
                 last_error: nil
             }, actions}

          {:error, reason} ->
            {:error, reason, %{state | runs: state.runs + 1, last_error: inspect(reason)}}
        end

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
    {:ok, state,
     [
       {:event, :executor_output_not_replayed,
        %{
          "reason" => "completed_output_already_recorded",
          "agent_id" => payload["agent_id"]
        }}
     ]}
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

    output_actions ++ maybe_complete_run(config, payload)
  end

  defp maybe_complete_run(config, payload) do
    if Map.get(config, "terminal_sink", false) and Map.get(config, "complete_run", false) do
      [{:complete_run, payload}]
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

    # We pass the overall invocation counter (to salt sandbox directories securely between distinct payloads or retries)
    invocation = Map.get(context, :invocation, 1)

    case runner.run(
           payload,
           config,
           message: message,
           attempt: attempt,
           invocation: invocation,
           coordinator_node: node(context.coordinator),
           job_id: context.job_id,
           agent_id: context.node.node_id,
           agent_type: Map.get(context.node, :agent_type),
           template_type: Map.get(context.node, :type, "generic"),
           agent_state: state.agent_state,
           bundle_root: context.bundle_root,
           manifest_path: context.manifest_path,
           payloads_path: context.payloads_path,
           event_callback: fn event_type, event_payload ->
             report_event(context, event_type, event_payload)
           end
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
      :ignore ->
        {:ok, state.agent_state, []}

      {:error, reason} ->
        {:error, reason}

      {:ok, payload} ->
        next_state = Map.get(payload, "next_state", state.agent_state)

        actions =
          structured_event_actions(payload) ++
            structured_emit_actions(payload, incoming) ++
            structured_completion_actions(payload, default_payload)

        {:ok, next_state, actions}
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
      Map.get(payload, "complete_step") == true ->
        [{:complete_step, default_payload}]

      Map.get(payload, "complete_step") not in [nil, false] ->
        [{:complete_step, payload["complete_step"]}]

      Map.get(payload, "complete_run") == true ->
        [{:complete_run, default_payload}]

      Map.get(payload, "complete_run") not in [nil, false] ->
        [{:complete_run, payload["complete_run"]}]

      true ->
        []
    end
  end

  defp decode_structured_stdout(result) do
    with stdout when is_binary(stdout) and stdout != "" <- Map.get(result, "stdout"),
         {:ok, decoded} <- Jason.decode(stdout) do
      cond do
        legacy_completion_payload?(decoded) ->
          {:error,
           %{
             "error" => "unsupported structured output key",
             "unsupported_keys" => legacy_completion_keys(decoded),
             "message" => "Use complete_step or complete_run instead of complete_job"
           }}

        structured_payload?(decoded) ->
          {:ok, decoded}

        true ->
          :ignore
      end
    else
      _ -> :ignore
    end
  end

  defp structured_payload?(decoded) when is_map(decoded) do
    Enum.any?(
      ["emit_messages", "events", "next_state", "complete_step", "complete_run"],
      &Map.has_key?(decoded, &1)
    )
  end

  defp structured_payload?(_decoded), do: false

  defp legacy_completion_payload?(decoded) when is_map(decoded) do
    Enum.any?(["complete_job", "complete_job?"], &Map.has_key?(decoded, &1))
  end

  defp legacy_completion_payload?(_decoded), do: false

  defp legacy_completion_keys(decoded) when is_map(decoded) do
    Enum.filter(["complete_job", "complete_job?"], &Map.has_key?(decoded, &1))
  end

  defp output_action?({:emit, _, _, _}), do: true
  defp output_action?({:emit, _, _}), do: true
  defp output_action?({:emit_to, _, _, _, _}), do: true
  defp output_action?({:emit_to, _, _, _}), do: true
  defp output_action?({:emit_message, _}), do: true
  defp output_action?(_action), do: false

  defp implicit_workflow_step_completion_actions(context, payload, structured_actions) do
    workflow = Map.get(context, :workflow)

    cond do
      not is_map(workflow) or map_size(workflow) == 0 ->
        []

      Enum.any?(structured_actions, &match?({:complete_step, _}, &1)) ->
        []

      true ->
        [{:complete_step, payload}]
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

  defp configured_lease_opts(config) do
    []
    |> maybe_put_int(:queue_timeout_ms, Map.get(config, "lease_queue_timeout_ms"))
    |> maybe_put_int(:queue_timeout_ms, Map.get(config, :lease_queue_timeout_ms))
    |> maybe_put_int(:max_queue_length, Map.get(config, "lease_max_queue_length"))
    |> maybe_put_int(:max_queue_length, Map.get(config, :lease_max_queue_length))
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
      node: to_string(Node.self()),
      execution_profile: Profile.profile_name(Map.get(context.node, :config, %{}))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp report_event(context, event_type, payload) do
    payload = workflow_payload(context, payload)

    case Map.get(context, :coordinator_reporter) do
      reporter
      when is_function(reporter, 3) ->
        if MirrorNeuron.Runtime.Delivery.coordinator_event_requires_ack?(event_type) do
          reporter.(
            "agent_event",
            %{"event_type" => to_string(event_type), "payload" => payload},
            "runner:#{event_type}"
          )
        else
          send(context.coordinator, {:agent_event, context.node.node_id, event_type, payload})
        end

      _other ->
        send(context.coordinator, {:agent_event, context.node.node_id, event_type, payload})
    end
  end

  defp workflow_payload(context, payload) do
    workflow =
      case Map.get(context, :workflow) do
        workflow when is_map(workflow) -> workflow
        _ -> %{}
      end

    cond do
      map_size(workflow) == 0 ->
        payload

      is_map(payload) ->
        Map.merge(workflow, payload)

      true ->
        workflow
    end
  end

  defp maybe_put_int(opts, _key, nil), do: opts

  defp maybe_put_int(opts, key, value) when is_integer(value) and value >= 0 do
    Keyword.put(opts, key, value)
  end

  defp maybe_put_int(opts, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> Keyword.put(opts, key, parsed)
      _ -> opts
    end
  end

  defp maybe_put_int(opts, _key, _value), do: opts
end
