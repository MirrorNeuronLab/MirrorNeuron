defmodule MirrorNeuron.Runtime.AgentWorker.Actions do
  @moduledoc "Routes handler output and reports completion through the owning workflow boundary."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AgentWorker.Observations
  alias MirrorNeuron.Runtime.AgentWorker.Reports
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.RouteCondition
  alias MirrorNeuron.Runtime.WorkflowMessage

  def execute_actions(actions, incoming, state) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {action, action_index}, :ok ->
      case execute_action(action, incoming, state, action_index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_action({:emit, message_type, payload}, incoming, state, action_index) do
    execute_action({:emit, message_type, payload, []}, incoming, state, action_index)
  end

  defp execute_action({:emit, message_type, payload, opts}, incoming, state, action_index) do
    matching_edges =
      Enum.filter(state.outbound_edges, fn edge ->
        edge.message_type == message_type or edge.message_type == "*"
      end)

    route_context = RouteCondition.context(incoming, payload, state.local_state)

    evaluated_edges =
      Enum.map(matching_edges, &evaluate_route_edge(&1, message_type, route_context, state))

    selected_edges = select_route_edges(evaluated_edges)

    if matching_edges != [] and selected_edges == [] do
      send(state.coordinator, {
        :agent_event,
        state.node.node_id,
        :route_not_matched,
        %{
          "from" => state.node.node_id,
          "message_type" => message_type,
          "candidate_count" => length(matching_edges)
        }
      })
    end

    Enum.reduce_while(selected_edges, :ok, fn edge, :ok ->
      send(state.coordinator, {
        :agent_event,
        state.node.node_id,
        :route_selected,
        %{
          "edge_id" => edge.edge_id,
          "from" => edge.from_node,
          "to" => edge.to_node,
          "message_type" => message_type,
          "routing_mode" => edge.routing_mode
        }
      })

      delivery_opts = Keyword.put(opts, :delivery_key, "#{action_index}:#{edge.edge_id}")

      result =
        Runtime.deliver(
          state.job_id,
          edge.to_node,
          build_message(state, incoming, edge.to_node, message_type, payload, delivery_opts),
          target_backpressure_opts(state, edge.to_node)
        )

      Observations.maybe_report_delivery_pressure(result, edge.to_node, message_type, state)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_action({:emit_to, to_node, message_type, payload}, incoming, state, action_index) do
    execute_action(
      {:emit_to, to_node, message_type, payload, []},
      incoming,
      state,
      action_index
    )
  end

  defp execute_action(
         {:emit_to, to_node, message_type, payload, opts},
         incoming,
         state,
         action_index
       ) do
    delivery_opts = Keyword.put(opts, :delivery_key, Integer.to_string(action_index))

    result =
      Runtime.deliver(
        state.job_id,
        to_node,
        build_message(state, incoming, to_node, message_type, payload, delivery_opts),
        target_backpressure_opts(state, to_node)
      )

    Observations.maybe_report_delivery_pressure(result, to_node, message_type, state)
    result
  end

  defp execute_action({:emit_message, message}, incoming, state, action_index) do
    normalized = Message.normalize!(message, job_id: state.job_id, from: state.node.node_id)
    to_node = Message.to(normalized)
    message_id = WorkflowMessage.output_id(state, incoming, to_node, action_index)

    normalized =
      normalized
      |> put_in(["envelope", "message_id"], message_id)
      |> put_in(
        ["headers"],
        WorkflowMessage.explicit_output_headers(state, incoming, normalized, action_index)
      )

    result =
      Runtime.deliver(state.job_id, to_node, normalized, target_backpressure_opts(state, to_node))

    Observations.maybe_report_delivery_pressure(
      result,
      to_node,
      Message.type(normalized),
      state
    )

    result
  end

  defp execute_action({:event, event_type, payload}, incoming, state, action_index) do
    normalized_event_type = to_string(event_type)
    payload = Reports.enrich_workflow_payload(payload, incoming)

    if Delivery.coordinator_event_requires_ack?(normalized_event_type) do
      Reports.enqueue_coordinator_report(
        state,
        incoming,
        "agent_event",
        %{"event_type" => normalized_event_type, "payload" => payload},
        action_index
      )
    else
      send(state.coordinator, {:agent_event, state.node.node_id, event_type, payload})
      :ok
    end
  end

  defp execute_action({:checkpoint, snapshot}, _incoming, state, _action_index)
       when is_map(snapshot) do
    send(state.coordinator, {:agent_checkpoint, state.node.node_id, snapshot})
    :ok
  end

  defp execute_action({:complete_step, result}, incoming, state, action_index) do
    Reports.enqueue_coordinator_report(
      state,
      incoming,
      "agent_event",
      %{
        "event_type" => "workflow_step_attempt_completed",
        "payload" => Reports.enrich_workflow_payload(result, incoming)
      },
      action_index
    )
  end

  defp execute_action({:complete_run, result}, incoming, state, action_index) do
    Reports.enqueue_coordinator_report(
      state,
      incoming,
      "agent_completed_run",
      %{"result" => result},
      action_index
    )
  end

  defp evaluate_route_edge(edge, message_type, route_context, state) do
    matched? = RouteCondition.matches?(edge.conditions, route_context)

    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :route_evaluated,
      %{
        "edge_id" => edge.edge_id,
        "from" => edge.from_node,
        "to" => edge.to_node,
        "message_type" => message_type,
        "routing_mode" => edge.routing_mode,
        "matched" => matched?
      }
    })

    {edge, matched?}
  end

  defp select_route_edges(evaluated_edges) do
    matching = evaluated_edges |> Enum.filter(fn {_edge, matched?} -> matched? end)

    cond do
      Enum.any?(evaluated_edges, fn {edge, _matched?} -> edge.routing_mode == "first_match" end) ->
        matching |> Enum.take(1) |> Enum.map(fn {edge, _matched?} -> edge end)

      true ->
        Enum.map(matching, fn {edge, _matched?} -> edge end)
    end
  end

  defp build_message(state, incoming, to_node, message_type, payload, opts) do
    WorkflowMessage.build(state, incoming, to_node, message_type, payload, opts)
  end

  defp target_backpressure_opts(state, to_node) do
    state.runtime_context
    |> Map.get(:backpressure_by_agent, %{})
    |> Map.get(to_node, [])
  end
end
