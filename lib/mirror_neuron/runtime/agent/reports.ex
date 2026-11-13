defmodule MirrorNeuron.Runtime.AgentWorker.Reports do
  @moduledoc "Durable coordinator reports and workflow identity carried by incoming messages."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.WorkflowMessage

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  def maybe_report_workflow_message(_state, _message, workflow, _status)
      when map_size(workflow) == 0,
      do: :ok

  def maybe_report_workflow_message(state, message, _workflow, status) do
    workflow_agent_steps = Map.get(state.runtime_context, :workflow_agent_steps, %{})

    if Map.has_key?(workflow_agent_steps, state.node.node_id) do
      enqueue_coordinator_report(
        state,
        message,
        "workflow_message_#{status}",
        %{"message" => Delivery.stable_workflow_message(message)},
        status
      )
    else
      :ok
    end
  end

  def enqueue_coordinator_report(state, incoming, kind, fields, delivery_key) do
    report_id = WorkflowMessage.coordinator_report_id(state, incoming, kind, delivery_key)

    body =
      fields
      |> Map.put("kind", kind)
      |> Map.put("agent_id", state.node.node_id)

    case Delivery.report(state.job_id, state.node.node_id, report_id, body,
           attempt_epoch: state.runtime_context[:lease_epoch]
         ) do
      :ok ->
        GenServer.cast(state.coordinator, :coordinator_delivery_available)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def workflow_context(message, state) do
    headers = Message.headers(message)

    step_id =
      workflow_step_id(message) ||
        Map.get(state.runtime_context[:workflow_agent_steps] || %{}, state.node.node_id)

    %{
      "run_id" =>
        Map.get(headers, "mn.workflow.run_id") || Map.get(state.runtime_context, :workflow_run_id),
      "step_id" => step_id,
      "graph_revision" => Map.get(headers, "mn.workflow.graph_revision"),
      "template_id" => Map.get(headers, "mn.workflow.template_id"),
      "region_id" => Map.get(headers, "mn.workflow.region_id"),
      "attempt_id" => Map.get(headers, "mn.workflow.attempt_id"),
      "attempt" => Map.get(headers, "mn.workflow.attempt"),
      "deadline_at" => Map.get(headers, "mn.workflow.deadline_at"),
      "heartbeat_deadline_at" => Map.get(headers, "mn.workflow.heartbeat_deadline_at"),
      "idempotency_key" => Map.get(headers, "mn.workflow.idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def enrich_workflow_payload(payload, incoming) do
    workflow = workflow_context_from_headers(incoming)

    cond do
      map_size(workflow) == 0 ->
        payload

      is_map(payload) ->
        Map.merge(workflow, stringify_keys(payload))

      true ->
        workflow
    end
  end

  defp workflow_context_from_headers(message) do
    headers = Message.headers(message)

    %{
      "workflow_run_id" => Map.get(headers, "mn.workflow.run_id"),
      "step" => Map.get(headers, "mn.workflow.step_id"),
      "step_id" => Map.get(headers, "mn.workflow.step_id"),
      "graph_revision" => Map.get(headers, "mn.workflow.graph_revision"),
      "template_id" => Map.get(headers, "mn.workflow.template_id"),
      "region_id" => Map.get(headers, "mn.workflow.region_id"),
      "attempt_id" => Map.get(headers, "mn.workflow.attempt_id"),
      "attempt" => Map.get(headers, "mn.workflow.attempt"),
      "deadline_at" => Map.get(headers, "mn.workflow.deadline_at"),
      "heartbeat_deadline_at" => Map.get(headers, "mn.workflow.heartbeat_deadline_at"),
      "idempotency_key" => Map.get(headers, "mn.workflow.idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp workflow_step_id(message) do
    message
    |> Message.headers()
    |> Map.get("mn.workflow.step_id")
  end
end
