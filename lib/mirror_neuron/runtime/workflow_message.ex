defmodule MirrorNeuron.Runtime.WorkflowMessage do
  @moduledoc "Deterministic agent output messages and logical-step boundary context."

  alias MirrorNeuron.Message

  def build(state, incoming, to_node, message_type, payload, opts \\ []) do
    headers =
      incoming
      |> Message.headers()
      |> headers_for_target(state, incoming, to_node)
      |> Map.merge(Keyword.get(opts, :headers, %{}))
      |> with_attempt_epoch(state)

    Message.new(state.job_id, state.node.node_id, to_node, message_type, payload,
      class: Keyword.get(opts, :class, Message.class(incoming)),
      correlation_id: Keyword.get(opts, :correlation_id, Message.correlation_id(incoming)),
      causation_id: Keyword.get(opts, :causation_id, Message.id(incoming)),
      content_type: Keyword.get(opts, :content_type, Message.content_type(incoming)),
      content_encoding: Keyword.get(opts, :content_encoding, Message.content_encoding(incoming)),
      headers: headers,
      artifacts: Keyword.get(opts, :artifacts, Message.artifacts(incoming)),
      stream: Keyword.get(opts, :stream, Message.stream(incoming)),
      message_id:
        Keyword.get_lazy(opts, :message_id, fn ->
          output_id(state, incoming, to_node, Keyword.get(opts, :delivery_key, message_type))
        end)
    )
  end

  def output_id(state, incoming, to_node, delivery_key) do
    [Message.id(incoming), state.node.node_id, to_node, to_string(delivery_key)]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  def with_attempt_epoch(headers, state) do
    case state.runtime_context[:lease_epoch] do
      epoch when is_integer(epoch) -> Map.put(headers, "mn.attempt_epoch", epoch)
      _epoch -> headers
    end
  end

  def coordinator_report_id(state, incoming, kind, delivery_key) do
    # A pending delivery can be readmitted into a new logical attempt. Its
    # reports contain that attempt's headers, so they need a separate receipt
    # from the prior attempt while transport replay keeps the same identity.
    [
      state.job_id,
      state.node.node_id,
      Message.id(incoming),
      kind,
      to_string(delivery_key),
      Message.headers(incoming)["mn.workflow.attempt_id"],
      state.runtime_context[:lease_epoch]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp headers_for_target(headers, state, incoming, to_node) do
    agent_steps = Map.get(state.runtime_context, :workflow_agent_steps, %{})
    source_step = Message.headers(incoming)["mn.workflow.step_id"]
    source_template = Message.headers(incoming)["mn.workflow.template_id"]

    case Map.get(agent_steps, to_node) do
      nil ->
        headers

      ^source_step ->
        headers

      ^source_template ->
        headers

      step_id ->
        headers
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
        |> Map.put("mn.workflow.run_id", Map.get(state.runtime_context, :workflow_run_id))
        |> Map.put("mn.workflow.step_id", step_id)
        |> Map.put("mn.workflow.source_step_id", source_step)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    end
  end
end
