defmodule MirrorNeuron.Runtime.AgentWorker.Observations do
  @moduledoc "Bounded agent observations, queue pressure and delivery diagnostics."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Backpressure

  def persist_observation(state) do
    observation = snapshot(state, durable_delivery_depth(state))

    case RedisStore.persist_agent(state.job_id, state.node.node_id, observation) do
      {:ok, _observation} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist agent observation for #{state.job_id}/#{state.node.node_id}: #{inspect(reason)}"
        )
    end

    send(
      state.coordinator,
      {:agent_pressure, state.node.node_id, observation.metadata["backpressure"]}
    )
  end

  @doc "Projects bounded runtime metadata without serializing the handler's private state."
  def snapshot(state, durable_depth) do
    pressure = pressure_snapshot(state, durable_depth)
    observation = execution_observation(state.local_state)

    metadata = %{
      "paused" => state.paused?,
      "backpressure" => pressure,
      "pending_message_count" => durable_depth,
      "lease_epoch" => state.runtime_context[:lease_epoch],
      "lease_owner" => state.runtime_context[:lease_owner],
      "execution_profile" =>
        get_in(state.runtime_context, [:execution_profiles, state.node.node_id]) ||
          get_in(state.node, [:config, "execution_profile"])
    }

    %{
      agent_id: state.node.node_id,
      node_id: state.node.node_id,
      agent_type: state.node.agent_type,
      type: Map.get(state.node, :type, "generic"),
      role: state.node.role,
      processed_messages: state.processed_messages,
      mailbox_depth: Backpressure.process_queue_depth(self()),
      assigned_node: to_string(Node.self()),
      last_heartbeat_at: Runtime.timestamp(),
      parent_job_id: state.job_id,
      last_error: observation.last_error,
      sandbox: observation.sandbox,
      lease: observation.lease,
      metadata: metadata
    }
  end

  defp execution_observation(local_state) when is_map(local_state) do
    last_error = Map.get(local_state, :last_error) || Map.get(local_state, "last_error")
    last_result = Map.get(local_state, :last_result) || Map.get(local_state, "last_result")

    if is_map(last_result) do
      lease = Map.get(last_result, :lease) || Map.get(last_result, "lease") || %{}

      %{
        last_error: compact_observation_error(last_error),
        sandbox: %{
          "name" => Map.get(last_result, :sandbox_name) || Map.get(last_result, "sandbox_name"),
          "status" => Map.get(last_result, :status) || Map.get(last_result, "status")
        },
        lease: Map.take(stringify_observation_map(lease), ["lease_id", "pool", "slots"])
      }
    else
      %{last_error: compact_observation_error(last_error), sandbox: nil, lease: %{}}
    end
  end

  defp execution_observation(_local_state),
    do: %{last_error: nil, sandbox: nil, lease: %{}}

  defp compact_observation_error(nil), do: nil

  defp compact_observation_error(error) do
    encoded =
      if is_binary(error) and String.valid?(error),
        do: error,
        else: inspect(error, limit: 50, printable_limit: 8_192)

    if byte_size(encoded) > 8_192,
      do: encoded |> binary_part(0, 8_192) |> trim_partial_codepoint(),
      else: encoded
  end

  # `encoded` starts as valid UTF-8, so at most three trailing bytes are removed.
  defp trim_partial_codepoint(text) do
    if String.valid?(text),
      do: text,
      else: text |> binary_part(0, byte_size(text) - 1) |> trim_partial_codepoint()
  end

  defp stringify_observation_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  def durable_delivery_depth(state) do
    case MirrorNeuron.Runtime.DeliveryChannels.depth(state.job_id, state.node.node_id) do
      {:ok, count} -> count
      {:error, _reason} -> state.mailbox_depth
    end
  end

  def pressure_snapshot(state, internal_depth) do
    internal_depth = if is_nil(internal_depth), do: state.mailbox_depth, else: internal_depth
    queue_depth = internal_depth

    Backpressure.snapshot(
      state.node.node_id,
      state.node,
      queue_depth,
      [],
      state.pressure_snapshot
    )
  end

  def maybe_report_delivery_pressure(:ok, _to_node, _message_type, _state), do: :ok

  def maybe_report_delivery_pressure(
        {:error, {:backpressure, details}},
        to_node,
        message_type,
        state
      ) do
    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :backpressure_signal,
      Map.merge(details, %{
        "from" => state.node.node_id,
        "to" => to_node,
        "message_type" => message_type
      })
    })
  end

  def maybe_report_delivery_pressure({:error, reason}, to_node, message_type, state) do
    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :delivery_failed,
      %{
        "from" => state.node.node_id,
        "to" => to_node,
        "message_type" => message_type,
        "reason" => inspect(reason)
      }
    })
  end
end
