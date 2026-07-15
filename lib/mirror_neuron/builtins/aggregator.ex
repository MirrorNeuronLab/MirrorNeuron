defmodule MirrorNeuron.Builtins.Aggregator do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    crew = normalize_crew(Map.get(node.config, "crew"))

    {:ok,
     %{
       config: node.config,
       messages: [],
       seen_agent_ids: [],
       complete_on_message: Map.get(node.config, "complete_on_message", false),
       complete_after: Map.get(node.config, "complete_after"),
       crew: crew,
       crew_input: nil,
       crew_outputs: %{},
       crew_dispatched: []
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    if state.crew do
      handle_crew_message(message, state, context)
    else
      handle_aggregate_message(message, state, context)
    end
  end

  defp handle_aggregate_message(message, state, context) do
    payload = payload(message) || %{}
    agent_id = if is_map(payload), do: Map.get(payload, "agent_id"), else: nil

    if is_binary(agent_id) and agent_id in state.seen_agent_ids do
      {:ok, state, [{:event, :aggregator_duplicate_ignored, %{"agent_id" => agent_id}}]}
    else
      messages = state.messages ++ [payload]

      next_state =
        if is_binary(agent_id) do
          %{state | messages: messages, seen_agent_ids: state.seen_agent_ids ++ [agent_id]}
        else
          %{state | messages: messages}
        end

      actions = [
        {:event, :aggregator_received, %{"count" => length(messages)}}
      ]

      if should_complete?(next_state, messages) do
        result = aggregate(messages, state.config, payload)

        completion_actions =
          maybe_complete_step(context, result) ++
            maybe_emit_aggregate(state.config, result) ++ maybe_complete_run(state.config, result)

        {:ok, next_state, actions ++ completion_actions}
      else
        {:ok, next_state, actions}
      end
    end
  end

  defp handle_crew_message(message, state, context) do
    payload = payload(message) || %{}
    node_id = if is_map(payload), do: Map.get(payload, "agent_id"), else: nil

    case crew_agent_by_node(state.crew, node_id) do
      nil -> receive_crew_input(payload, state, context)
      agent -> receive_crew_output(agent, payload, state, context)
    end
  end

  defp receive_crew_input(payload, %{crew_input: nil} = state, _context) do
    state = %{state | crew_input: payload}
    {state, actions} = dispatch_ready_crew_agents(state)
    {:ok, state, [{:event, :crew_step_started, crew_event_payload(state)} | actions]}
  end

  defp receive_crew_input(_payload, state, _context) do
    {:ok, state, [{:event, :crew_step_duplicate_input_ignored, crew_event_payload(state)}]}
  end

  defp receive_crew_output(agent, payload, state, _context) do
    agent_id = agent["agent_id"]

    if Map.has_key?(state.crew_outputs, agent_id) do
      {:ok, state,
       [
         {:event, :crew_agent_duplicate_output_ignored,
          Map.merge(crew_event_payload(state), %{"agent_id" => agent_id})}
       ]}
    else
      state = %{state | crew_outputs: Map.put(state.crew_outputs, agent_id, payload)}
      {state, dispatch_actions} = dispatch_ready_crew_agents(state)

      received_event =
        {:event, :crew_agent_output_received,
         Map.merge(crew_event_payload(state), %{"agent_id" => agent_id})}

      if crew_complete?(state) do
        result = crew_result(state)

        actions =
          [received_event | dispatch_actions] ++
            [
              {:event, :crew_step_completed, crew_event_payload(state)},
              {:emit, state.crew["completion_message_type"], result},
              {:complete_step, result}
            ] ++ maybe_complete_run(state.config, result)

        {:ok, state, actions}
      else
        {:ok, state, [received_event | dispatch_actions]}
      end
    end
  end

  defp dispatch_ready_crew_agents(state) do
    ready =
      Enum.filter(state.crew["agents"], fn agent ->
        agent_id = agent["agent_id"]

        agent_id not in state.crew_dispatched and
          Enum.all?(agent["needs"], &Map.has_key?(state.crew_outputs, &1))
      end)

    actions =
      Enum.flat_map(ready, fn agent ->
        input = %{
          "step_id" => state.crew["step_id"],
          "agent_id" => agent["agent_id"],
          "step_input" => state.crew_input,
          "agent_outputs" =>
            Map.new(agent["needs"], fn dependency ->
              {dependency, crew_output_payload(state.crew_outputs[dependency])}
            end),
          "artifact_refs" =>
            agent["needs"]
            |> Enum.flat_map(&crew_output_artifacts(state.crew_outputs[&1]))
        }

        [
          {:event, :crew_agent_dispatched,
           Map.merge(crew_event_payload(state), %{"agent_id" => agent["agent_id"]})},
          {:emit, agent["input_message_type"], input}
        ]
      end)

    dispatched = state.crew_dispatched ++ Enum.map(ready, & &1["agent_id"])
    {%{state | crew_dispatched: Enum.uniq(dispatched)}, actions}
  end

  defp crew_complete?(state),
    do: map_size(state.crew_outputs) == length(state.crew["agents"])

  defp crew_result(state) do
    agent_outputs =
      Map.new(state.crew["agents"], fn agent ->
        agent_id = agent["agent_id"]
        {agent_id, crew_output_payload(state.crew_outputs[agent_id])}
      end)

    agent_artifacts =
      Map.new(state.crew["agents"], fn agent ->
        agent_id = agent["agent_id"]
        {agent_id, crew_output_artifacts(state.crew_outputs[agent_id])}
      end)

    %{
      "step_id" => state.crew["step_id"],
      "agent_outputs" => agent_outputs,
      "agent_artifacts" => agent_artifacts,
      "artifact_refs" => agent_artifacts |> Map.values() |> List.flatten(),
      "count" => map_size(agent_outputs)
    }
  end

  defp crew_output_payload(%{"outputs" => outputs}) when is_map(outputs), do: outputs
  defp crew_output_payload(payload) when is_map(payload), do: payload
  defp crew_output_payload(_payload), do: %{}

  defp crew_output_artifacts(%{"artifacts" => artifacts}) when is_list(artifacts),
    do: Enum.filter(artifacts, &is_map/1)

  defp crew_output_artifacts(_payload), do: []

  defp crew_event_payload(state) do
    %{
      "step_id" => state.crew["step_id"],
      "agent_count" => length(state.crew["agents"]),
      "completed_agent_count" => map_size(state.crew_outputs)
    }
  end

  defp crew_agent_by_node(nil, _node_id), do: nil

  defp crew_agent_by_node(crew, node_id) when is_binary(node_id) do
    Enum.find(crew["agents"], &(Map.get(&1, "node_id") == node_id))
  end

  defp crew_agent_by_node(_crew, _node_id), do: nil

  defp normalize_crew(%{"step_id" => step_id, "agents" => agents} = crew)
       when is_binary(step_id) and is_list(agents) and agents != [] do
    normalized_agents =
      Enum.map(agents, fn agent ->
        %{
          "agent_id" => to_string(Map.fetch!(agent, "agent_id")),
          "node_id" => to_string(Map.fetch!(agent, "node_id")),
          "needs" => Enum.map(Map.get(agent, "needs", []), &to_string/1),
          "input_message_type" => to_string(Map.fetch!(agent, "input_message_type"))
        }
      end)

    %{
      "step_id" => step_id,
      "agents" => normalized_agents,
      "completion_message_type" =>
        to_string(Map.get(crew, "completion_message_type") || "#{step_id}_completed")
    }
  end

  defp normalize_crew(_crew), do: nil

  defp aggregate(messages, _config, last_message) do
    %{"messages" => messages, "count" => length(messages), "last_message" => last_message}
  end

  defp maybe_emit_aggregate(config, result) do
    case Map.fetch(config, "output_message_type") do
      {:ok, message_type} when is_binary(message_type) and message_type != "" ->
        [
          {:emit, message_type, result,
           [
             class: "event",
             headers: %{
               "schema_ref" => "com.mirrorneuron.aggregator.result",
               "schema_version" => "1.0.0"
             }
           ]}
        ]

      _ ->
        []
    end
  end

  defp maybe_complete_run(config, result) do
    if Map.get(config, "terminal_sink", false) and Map.get(config, "complete_run", false) do
      [{:complete_run, result}]
    else
      []
    end
  end

  defp maybe_complete_step(context, result) do
    case Map.get(context, :workflow) do
      workflow when is_map(workflow) and map_size(workflow) > 0 -> [{:complete_step, result}]
      _other -> []
    end
  end

  defp should_complete?(state, messages) do
    state.complete_on_message or
      (is_integer(state.complete_after) and state.complete_after > 0 and
         length(messages) >= state.complete_after)
  end
end
