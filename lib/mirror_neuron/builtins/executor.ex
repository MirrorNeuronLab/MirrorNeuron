defmodule MirrorNeuron.Builtins.Executor do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Builtins.StepContract
  alias MirrorNeuron.Message
  alias MirrorNeuron.Artifacts.StagedArtifact
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
    "artifact_not_ready",
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
        with {:ok, default_payload} <-
               bounded_default_payload(result, payload, attempts, lease, state.config, context) do
          routed_output_payload = routed_output_payload(result, default_payload, payload)

          case structured_actions(result, state, normalized_message, routed_output_payload) do
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
                    routed_output_payload,
                    structured_actions,
                    state.config
                  ) ++
                  default_output_actions(state.config, routed_output_payload) ++
                  structured_output_actions

              {:ok,
               %{
                 state
                 | runs: state.runs + 1,
                   agent_state: structured_state,
                   last_output_payload: routed_output_payload,
                   last_result: Map.put(Map.put(result, "attempts", attempts), "lease", lease),
                   last_error: nil
               }, actions}

            {:error, reason} ->
              {:error, reason, %{state | runs: state.runs + 1, last_error: inspect(reason)}}
          end
        else
          {:error, reason} ->
            error = %{"error" => "failed to stage executor result", "reason" => inspect(reason)}
            {:error, error, %{state | runs: state.runs + 1, last_error: inspect(error)}}
        end

      {:error, reason, attempts} ->
        error = enrich_error(reason, attempts)

        case Map.get(state.config, "failure_message_type") do
          message_type when is_binary(message_type) and message_type != "" ->
            metadata =
              case Map.get(payload, "_mn_step") do
                value when is_map(value) -> value
                _ -> %{}
              end

            diagnostics =
              case Map.get(metadata, "diagnostics") do
                value when is_map(value) -> value
                _ -> %{}
              end

            fallback_metadata =
              Map.put(
                metadata,
                "diagnostics",
                Map.merge(diagnostics, %{
                  "fallback_used" => true,
                  "failed_agent_id" => context.node.node_id
                })
              )

            fallback_payload = %{
              "agent_id" => context.node.node_id,
              "outputs" => %{
                "error" => error,
                "fallback_used" => true,
                "failed_agent_id" => context.node.node_id
              },
              "artifacts" => Message.artifacts(normalized_message),
              "status" => "failed",
              "_mn_step" => fallback_metadata
            }

            {:ok,
             %{
               state
               | runs: state.runs + 1,
                 last_output_payload: fallback_payload,
                 last_error: inspect(error)
             },
             [
               {:event, :executor_fallback_dispatched,
                %{"agent_id" => context.node.node_id, "error" => error}},
               {:emit, message_type, fallback_payload,
                [artifacts: Message.artifacts(normalized_message)]}
             ]}

          _ ->
            {:error, error, %{state | runs: state.runs + 1, last_error: inspect(error)}}
        end
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
    runner_config = with_step_result_pointer(config, context, attempt)
    runner = resolve_runner(config)

    # We pass the overall invocation counter (to salt sandbox directories securely between distinct payloads or retries)
    invocation = Map.get(context, :invocation, 1)

    case runner.run(
           payload,
           runner_config,
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
        case attach_structured_result(result, runner_config) do
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
    case decode_structured_result(result) do
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

  defp decode_structured_result(result) do
    with {:ok, decoded} <- decoded_result_payload(result) do
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

  defp decoded_result_payload(%{"structured_result" => decoded}) when is_map(decoded),
    do: {:ok, decoded}

  defp decoded_result_payload(result) do
    with stdout when is_binary(stdout) and stdout != "" <- Map.get(result, "stdout"),
         {:ok, decoded} <- Jason.decode(stdout) do
      {:ok, decoded}
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

  defp implicit_workflow_step_completion_actions(
         context,
         payload,
         structured_actions,
         config
       ) do
    workflow = Map.get(context, :workflow)

    cond do
      Map.get(config, "workflow_complete_step", true) == false ->
        []

      not is_map(workflow) or map_size(workflow) == 0 ->
        []

      Enum.any?(structured_actions, &match?({:complete_step, _}, &1)) ->
        []

      true ->
        [{:complete_step, payload}]
    end
  end

  defp routed_output_payload(result, default_payload, input_payload) do
    with {:ok, decoded} when is_map(decoded) <- decoded_result_payload(result),
         true <- sdk_step_result?(decoded) do
      decoded
      |> Map.take([
        "outputs",
        "artifacts",
        "metrics",
        "status",
        "workflow_step_id",
        "run_id",
        "runtime_step_mode"
      ])
      |> Map.put("agent_id", default_payload["agent_id"])
      |> propagate_step_metadata(input_payload)
    else
      _ -> default_payload
    end
  end

  defp propagate_step_metadata(payload, input) when is_map(input) do
    metadata = StepContract.reference_metadata(input)
    if map_size(metadata) > 0, do: Map.put(payload, "_mn_step", metadata), else: payload
  end

  defp propagate_step_metadata(payload, _default_payload), do: payload

  defp bounded_default_payload(result, input, attempts, lease, config, context) do
    payload = %{
      "agent_id" => context.node.node_id,
      "sandbox" =>
        result
        |> Map.drop(["structured_result"])
        |> Map.merge(%{"attempts" => attempts, "lease" => lease})
    }

    opts = staging_opts(config, context)

    case StagedArtifact.maybe_stage_output(payload, opts) do
      {:ok, ^payload, nil} ->
        {:ok, propagate_step_metadata(payload, input)}

      {:ok, staged_output, reference} ->
        {:ok,
         %{
           "agent_id" => context.node.node_id,
           "outputs" => staged_output,
           "artifacts" => [reference],
           "status" => "completed"
         }
         |> propagate_step_metadata(input)}

      {:error, _reason} = error ->
        error
    end
  end

  defp staging_opts(config, context) do
    environment = Map.get(config, "environment", %{})
    workflow = Map.get(context, :workflow, %{})

    [
      kind: "executor_result",
      submission_path: Map.get(environment, "MN_JOB_SHARED_STORAGE_ROOT"),
      submission_id: Map.get(environment, "MN_STORAGE_SUBMISSION_ID"),
      run_id: Map.get(workflow, "run_id") || context.job_id
    ]
  end

  defp with_step_result_pointer(config, context, attempt) do
    environment = Map.get(config, "environment", %{})
    submission_path = Map.get(environment, "MN_JOB_SHARED_STORAGE_ROOT")

    if sdk_step_runtime?(config) and is_binary(submission_path) and submission_path != "" do
      workflow = Map.get(context, :workflow, %{})
      run_id = Map.get(workflow, "run_id") || context.job_id || "run"
      attempt_id = Map.get(workflow, "attempt_id") || "attempt-#{attempt}"

      pointer =
        Path.join([
          submission_path,
          "outputs",
          "runs",
          safe_component(run_id),
          "artifacts",
          "results",
          safe_component(context.node.node_id),
          safe_component(attempt_id) <> "-#{attempt}.json"
        ])

      Map.put(config, "environment", Map.put(environment, "MN_STEP_RESULT_FILE", pointer))
    else
      config
    end
  end

  defp sdk_step_runtime?(config) do
    case Map.get(config, "command") do
      command when is_binary(command) ->
        String.contains?(command, "mn_sdk.step_runtime")

      command when is_list(command) ->
        Enum.any?(command, &String.contains?(to_string(&1), "mn_sdk.step_runtime"))

      _ ->
        false
    end
  end

  defp attach_structured_result(result, config) do
    environment = Map.get(config, "environment", %{})

    case Map.get(environment, "MN_STEP_RESULT_FILE") do
      path when is_binary(path) and path != "" ->
        try do
          resolved =
            StagedArtifact.resolve_pointer!(path,
              submission_path: Map.get(environment, "MN_JOB_SHARED_STORAGE_ROOT")
            )

          {:ok, Map.put(result, "structured_result", resolved)}
        rescue
          error in StagedArtifact.NotReadyError ->
            {:error,
             %{
               "error" => Exception.message(error),
               "code" => error.code,
               "retryable" => error.retryable
             }}

          error in StagedArtifact.IntegrityError ->
            {:error, %{"error" => Exception.message(error), "code" => "artifact_integrity_error"}}
        end

      _ ->
        {:ok, result}
    end
  end

  defp safe_component(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim(".-")
    |> case do
      "" -> "run"
      normalized -> normalized
    end
  end

  defp sdk_step_result?(decoded) do
    is_map(Map.get(decoded, "outputs")) and
      is_list(Map.get(decoded, "artifacts")) and
      is_map(Map.get(decoded, "metrics")) and
      is_binary(Map.get(decoded, "status"))
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
