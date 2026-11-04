defmodule MirrorNeuron.Runtime.WorkflowMessage do
  @moduledoc "Deterministic agent output messages and logical-step boundary context."

  alias MirrorNeuron.Message

  @effect_origin "mn.workflow.effect_origin"

  def build(state, incoming, to_node, message_type, payload, opts \\ []) do
    delivery_key = Keyword.get(opts, :delivery_key, message_type)

    headers =
      incoming
      |> Message.headers()
      |> headers_for_target(state, incoming, to_node)
      |> Map.merge(Map.delete(Keyword.get(opts, :headers, %{}), @effect_origin))
      |> advance_effect_origin(state, to_node, delivery_key, opts[:message_id])
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
          output_id(state, incoming, to_node, delivery_key)
        end)
    )
  end

  def output_id(state, incoming, to_node, delivery_key) do
    delivery_id(Message.id(incoming), state.node.node_id, to_node, delivery_key)
  end

  defp delivery_id(parent_id, from, to, delivery_key) do
    [parent_id, from, to, to_string(delivery_key)]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  # A retry needs fresh transport IDs for ACKs and attempt fencing, but an
  # SDK effect already committed on this route must retain its original owner.
  def retry_delivery(message, new_id) do
    headers = Message.headers(message)

    headers =
      case effect_origin(message) do
        nil -> headers
        origin -> Map.put(headers, @effect_origin, origin)
      end

    message |> put_in(["headers"], headers) |> put_in(["envelope", "message_id"], new_id)
  end

  def invocation_key(message) when is_map(message) do
    case effect_origin(message) do
      %{"step_key" => key, "delivery_id" => id} ->
        [key, Message.to(message), id]
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      nil ->
        nil
    end
  end

  def invocation_key(_message), do: nil

  defp effect_origin(message) do
    headers = Message.headers(message)

    case headers["mn.workflow.idempotency_key"] do
      key when is_binary(key) and key != "" ->
        case headers[@effect_origin] do
          %{"step_key" => step_key, "delivery_id" => id} = origin
          when is_binary(step_key) and is_binary(id) ->
            origin

          _ ->
            %{"step_key" => key, "delivery_id" => Message.id(message)}
        end

      _ ->
        nil
    end
  end

  defp advance_effect_origin(
         %{@effect_origin => %{"delivery_id" => parent_id}} = headers,
         state,
         to,
         key,
         explicit_id
       ) do
    id = explicit_id || delivery_id(parent_id, state.node.node_id, to, key)
    put_in(headers, [@effect_origin, "delivery_id"], id)
  end

  defp advance_effect_origin(headers, _state, _to, _key, _explicit_id),
    do: Map.delete(headers, @effect_origin)

  def explicit_output_headers(state, incoming, outgoing, action_index) do
    original = Message.headers(incoming)
    headers = Map.delete(Message.headers(outgoing), @effect_origin)

    if is_map(original[@effect_origin]) and
         is_binary(original["mn.workflow.idempotency_key"]) and
         headers["mn.workflow.idempotency_key"] == original["mn.workflow.idempotency_key"] and
         headers["mn.workflow.step_id"] == original["mn.workflow.step_id"] do
      headers
      |> Map.put(@effect_origin, original[@effect_origin])
      |> advance_effect_origin(state, Message.to(outgoing), action_index, nil)
    else
      headers
    end
    |> with_attempt_epoch(state)
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
          "mn.workflow.idempotency_key",
          @effect_origin
        ])
        |> Map.put("mn.workflow.run_id", Map.get(state.runtime_context, :workflow_run_id))
        |> Map.put("mn.workflow.step_id", step_id)
        |> Map.put("mn.workflow.source_step_id", source_step)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    end
  end
end
