defmodule MirrorNeuron.Builtins.Executor.Events do
  @moduledoc "Reports durable invocation observations with workflow context."

  def report_event(context, event_type, payload) do
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
end
