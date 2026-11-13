defmodule MirrorNeuron.Runtime.WorkflowLedger.Messages do
  @moduledoc "Workflow delivery identities, headers, message status and step addressing."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.DynamicWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger.State
  alias MirrorNeuron.Runtime.WorkflowLedger.Values

  def decorate_message(state, agent_id, message, extra_headers \\ %{}) do
    if State.enabled?(state) do
      step_id = step_id_for_message(state, agent_id, message)

      if step_id do
        step = State.get_step(state, step_id)
        decorate_step_message(state, step, message, extra_headers)
      else
        message
      end
    else
      message
    end
  end

  def decorate_step_message(state, step, message, extra_headers \\ %{}) do
    headers =
      message
      |> Message.headers()
      |> Map.drop([
        "mn.workflow.step_id",
        "mn.workflow.graph_revision",
        "mn.workflow.template_id",
        "mn.workflow.region_id",
        "mn.workflow.attempt_id",
        "mn.workflow.attempt",
        "mn.workflow.deadline_at",
        "mn.workflow.heartbeat_deadline_at",
        "mn.workflow.idempotency_key"
      ])
      |> Map.merge(%{
        "mn.workflow.run_id" => State.run_id(state),
        "mn.workflow.step_id" => step["id"],
        "mn.workflow.graph_revision" => DynamicWorkflow.graph_revision(state),
        "mn.workflow.template_id" => Map.get(step, "template_id"),
        "mn.workflow.region_id" => Map.get(step, "region_id"),
        "mn.workflow.timeout_seconds" => Map.get(step, "timeout_seconds"),
        "mn.workflow.heartbeat_timeout_ms" => Map.get(step, "beacon_timeout_ms")
      })
      |> Map.merge(Values.stringify_map(extra_headers))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    put_in(message, ["headers"], headers)
  end

  def maybe_put_last_message(step, message) when is_map(message),
    do: Map.put(step, "last_message", message)

  def maybe_put_last_message(step, _message), do: step

  def maybe_put_blocked_message_status(state, message, step_id, now, reason)
      when is_map(message),
      do: put_message_status(state, message, step_id, "blocked", now, %{"reason" => reason})

  def maybe_put_blocked_message_status(state, _message, _step_id, _now, _reason), do: state

  def step_id_for_message(state, agent_id, message) do
    headers = Message.headers(message)
    Map.get(headers, "mn.workflow.step_id") || State.step_for_agent(state, agent_id)
  end

  defp step_id_from_payload(state, agent_id, payload) when is_map(payload) do
    Map.get(payload, "step") ||
      Map.get(payload, "step_id") ||
      Map.get(payload, "workflow_step_id") ||
      Map.get(payload, "phase") ||
      Map.get(payload, "phase_id") ||
      State.active_step_for_agent(state, agent_id) || State.step_for_agent(state, agent_id)
  end

  defp step_id_from_payload(state, agent_id, _payload),
    do: State.active_step_for_agent(state, agent_id) || State.step_for_agent(state, agent_id)

  def step_id_from_agent_event(state, agent_id, event_type, payload) do
    case Values.normalize_event_type(event_type) do
      type when type in ["workflow_graph_patch", "workflow_controller_checkpoint"] ->
        State.active_step_for_agent(state, agent_id) || State.step_for_agent(state, agent_id)

      _ ->
        step_id_from_payload(state, agent_id, payload)
    end
  end

  def put_message_status(state, message, step_id, status, now, extra \\ %{}) do
    message_id = safe_message_id(message)

    if is_binary(message_id) do
      record =
        %{
          "message_id" => message_id,
          "step_id" => step_id,
          "status" => status,
          "updated_at" => now
        }
        |> Map.merge(extra)

      update_in(state, ["messages"], fn
        messages when is_map(messages) ->
          existing = Map.get(messages, message_id, %{})
          Map.put(messages, message_id, Map.merge(existing, record))

        _ ->
          %{message_id => record}
      end)
    else
      state
    end
  end

  def safe_message_id(message) do
    Message.id(message)
  rescue
    _ -> nil
  end
end
