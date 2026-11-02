defmodule MirrorNeuron.Runtime.InvocationOutbox do
  @moduledoc "Fenced invocation journal and agent checkpoint for deferred output delivery."
  alias MirrorNeuron.{Message, Persistence.DeliveryStore}
  @limit 1_048_576

  def recover(state) do
    if versioned?(state) do
      with {:ok, encoded} <-
             DeliveryStore.read_checkpoint(
               state.job_id,
               state.node.node_id,
               state.runtime_context[:lease_epoch]
             ) do
        case encoded do
          nil ->
            {:ok, state}

          _ ->
            with {:ok, {sequence, local_state}} <- decode(encoded),
                 true <- is_integer(sequence) and is_map(local_state) do
              {:ok, %{state | local_state: local_state, processed_messages: sequence}}
            else
              {:error, :checkpoint_artifact_pending} = waiting -> waiting
              _ -> {:error, :invalid_agent_checkpoint}
            end
        end
      end
    else
      {:ok, state}
    end
  end

  def admit(message, state) do
    if versioned?(state) do
      bucket = Map.get(state, :delivery_bucket, state.node.node_id)

      with {:ok, encoded} <- DeliveryStore.read_outbox(state.job_id, bucket, Message.id(message)) do
        case encoded do
          nil ->
            MirrorNeuron.Runtime.WorkflowAdmission.prepare(message, state)

          _ ->
            with {:ok, {_identity, _sequence, _local, _actions, saved}} <- decode(encoded),
                 true <- Message.id(saved) == Message.id(message) do
              {:ok, saved}
            else
              {:error, :checkpoint_artifact_pending} -> {:defer, :checkpoint_artifact_pending}
              _ -> {:error, :invalid_outbox}
            end
        end
      end
    else
      MirrorNeuron.Runtime.WorkflowAdmission.prepare(message, state)
    end
  end

  def run(message, state, handler) do
    if versioned?(state) do
      bucket = Map.get(state, :delivery_bucket, state.node.node_id)

      with {:ok, encoded} <- DeliveryStore.read_outbox(state.job_id, bucket, Message.id(message)) do
        case encoded do
          nil -> invoke(message, state, bucket, handler)
          _ -> restore(encoded, message, state)
        end
      else
        {:error, reason} -> {:defer, {:outbox_unavailable, reason}, state.local_state}
      end
    else
      handler.()
    end
  end

  defp invoke(message, state, bucket, handler) do
    case DeliveryStore.begin_invocation(
           state.job_id,
           bucket,
           Message.id(message),
           state.delivery_consumer
         ) do
      {:ok, "started"} ->
        case handler.() do
          {:ok, local_state, actions} ->
            persist(message, state, bucket, local_state, actions)

          result ->
            DeliveryStore.abandon_invocation(
              state.job_id,
              bucket,
              Message.id(message),
              state.delivery_consumer
            )

            result
        end

      {:ok, _phase} ->
        {:error, :invocation_outcome_unconfirmed, state.local_state}

      {:error, reason} ->
        {:defer, {:outbox_unavailable, reason}, state.local_state}
    end
  end

  defp persist(message, state, bucket, local_state, actions) do
    sequence = state.processed_messages + 1
    record = {identity(message, state), sequence, local_state, actions, message}

    with {:ok, encoded} <- encode(record, state),
         {:ok, checkpoint} <- encode({sequence, local_state}, state),
         :ok <-
           DeliveryStore.write_outbox(
             state.job_id,
             bucket,
             Message.id(message),
             encoded,
             state.delivery_consumer,
             state.node.node_id,
             state.runtime_context[:lease_epoch],
             checkpoint
           ) do
      {:checkpointed, local_state, actions, sequence, command_result(local_state)}
    else
      # The durable executing marker prevents a crash or an unconfirmed write
      # from authorizing another invocation. Recovery must reconcile it.
      {:error, reason} -> {:error, {:invocation_outcome_unconfirmed, reason}, local_state}
    end
  end

  defp restore(encoded, message, state) do
    expected = identity(message, state)

    with {:ok, {^expected, sequence, local_state, actions, _saved}} <- decode(encoded),
         true <- is_integer(sequence) do
      current = if sequence <= state.processed_messages, do: state.local_state, else: local_state

      {:checkpointed, current, actions, max(sequence, state.processed_messages),
       command_result(local_state)}
    else
      _ -> {:error, :outbox_identity_mismatch, state.local_state}
    end
  end

  defp command_result(local_state),
    do: Map.get(local_state, :last_output_payload, %{"handled" => true})

  defp versioned?(state), do: Map.get(state.runtime_context, :delivery_version, 1) == 2

  defp identity(message, state),
    do:
      {Message.id(message), Message.headers(message)["mn.workflow.attempt_id"],
       state.runtime_context[:lease_epoch]}

  defp encode(value, state) do
    if serializable?(value) do
      encoded = value |> :erlang.term_to_binary() |> Base.encode64()

      cond do
        byte_size(encoded) <= @limit ->
          {:ok, encoded}

        byte_size(encoded) > 64 * @limit ->
          {:error, :outbox_too_large}

        true ->
          with {:ok, job} <- MirrorNeuron.Persistence.RedisStore.fetch_job(state.job_id),
               {:ok, ref} <-
                 MirrorNeuron.Artifacts.StagedArtifact.stage_from_manifest(
                   encoded,
                   job["manifest"],
                   run_id: state.job_id,
                   kind: "invocation_checkpoint"
                 ) do
            {:ok, Jason.encode!(%{"artifact" => ref})}
          end
      end
    else
      {:error, :agent_state_not_checkpointable}
    end
  end

  defp decode("{" <> _ = encoded) when byte_size(encoded) <= 16_384 do
    with {:ok, %{"artifact" => ref}} <- Jason.decode(encoded) do
      ref |> MirrorNeuron.Artifacts.StagedArtifact.resolve!(timeout_ms: 0) |> decode()
    end
  rescue
    MirrorNeuron.Artifacts.StagedArtifact.NotReadyError -> {:error, :checkpoint_artifact_pending}
    _ -> {:error, :invalid_checkpoint_artifact}
  end

  defp decode(encoded) when is_binary(encoded) and byte_size(encoded) <= 64 * @limit do
    with {:ok, binary} <- Base.decode64(encoded),
         false <- match?(<<131, 80, _::binary>>, binary) do
      value = :erlang.binary_to_term(binary, [:safe])
      if serializable?(value), do: {:ok, value}, else: {:error, :invalid_outbox}
    else
      _ -> {:error, :invalid_outbox}
    end
  rescue
    _ -> {:error, :invalid_outbox}
  end

  defp decode(_), do: {:error, :invalid_outbox}

  defp serializable?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> serializable?(k) and serializable?(v) end)

  defp serializable?(value) when is_list(value), do: Enum.all?(value, &serializable?/1)
  defp serializable?(value) when is_tuple(value), do: value |> Tuple.to_list() |> serializable?()
  defp serializable?(value), do: is_binary(value) or is_atom(value) or is_number(value)
end
