defmodule MirrorNeuron.Builtins.Executor.Actions do
  @moduledoc "Interprets typed worker results, preserving output order and explicit completion authority."

  alias MirrorNeuron.Builtins.Executor.Decoding
  alias MirrorNeuron.Builtins.Executor.Events
  alias MirrorNeuron.Message

  def default_output_actions(config, payload) do
    if config["block_event"] do
      []
    else
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
  end

  defp maybe_complete_run(config, payload) do
    if Map.get(config, "terminal_sink", false) and Map.get(config, "complete_run", false) do
      [{:complete_run, payload}]
    else
      []
    end
  end

  def structured_actions(result, state, incoming, default_payload, context) do
    case Decoding.decode_structured_result(result) do
      :ignore ->
        if state.config["block_event"],
          do:
            {:error, %{"error" => "event worker omitted its typed result", "retryable" => false}},
          else: {:ok, state.agent_state, []}

      {:error, reason} ->
        {:error, reason}

      {:ok, payload} ->
        if Map.has_key?(payload, "event_result") do
          with {:ok, next_state, emissions, events} <-
                 MirrorNeuron.Builtins.BlockEventResult.interpret(
                   payload,
                   state.agent_state,
                   state.config
                 ),
               {:ok, publication_warnings} <-
                 MirrorNeuron.Builtins.BlockEventPublication.publish(
                   payload,
                   state.config,
                   context
                 ) do
            # Optional delivery warnings may disappear after repair. Keep them
            # outside the ordered action list so replay cannot renumber durable
            # business events, step completion or message delivery actions.
            Enum.each(
              publication_warnings,
              &Events.report_event(context, :block_publication_warning, &1)
            )

            actions =
              structured_event_actions(%{"events" => events}) ++
                structured_emit_actions(%{"emit_messages" => emissions}, incoming)

            {:ok, next_state, actions}
          end
        else
          if state.config["block_event"] do
            {:error, %{"error" => "event worker omitted its typed result", "retryable" => false}}
          else
            next_state = Map.get(payload, "next_state", state.agent_state)

            actions =
              structured_event_actions(payload) ++
                structured_emit_actions(payload, incoming) ++
                structured_completion_actions(payload, default_payload)

            {:ok, next_state, actions}
          end
        end
    end
  end

  defp structured_event_actions(payload) do
    payload
    |> Map.get("events", [])
    |> Enum.flat_map(fn
      %{"type" => type, "payload" => event_payload}
      when is_binary(type) and is_map(event_payload) ->
        [{:event, event_type(type), event_payload}]

      _ ->
        []
    end)
  end

  defp event_type(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> type
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

  def output_action?({:emit, _, _, _}), do: true

  def output_action?({:emit, _, _}), do: true

  def output_action?({:emit_to, _, _, _, _}), do: true

  def output_action?({:emit_to, _, _, _}), do: true

  def output_action?({:emit_message, _}), do: true

  def output_action?(_action), do: false

  def implicit_workflow_step_completion_actions(
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
end
