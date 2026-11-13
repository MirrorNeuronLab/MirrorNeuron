defmodule MirrorNeuron.Persistence.DeliveryStore.Receipts do
  @moduledoc "Reads receipts and expires deliveries without shortening protected replay retention."

  alias MirrorNeuron.Persistence.DeliveryStore.Decoding
  alias MirrorNeuron.Persistence.DeliveryStore.Keys
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Persistence.DeliveryStore.Transport

  @doc false
  def fetch_delivery_receipt(job_id, agent_id, message_id) do
    case Transport.command(["HGETALL", Keys.delivery_receipt_key(job_id, agent_id, message_id)]) do
      {:ok, []} ->
        {:error, :not_found}

      {:ok, values} ->
        {:ok, values |> Decoding.pairs_to_map() |> Decoding.parse_delivery_receipt()}

      {:error, reason} ->
        {:error, Transport.format_reason(reason)}
    end
  end

  @doc false
  def delivery_pending_count(job_id, agent_id) do
    case Transport.command(["GET", Keys.delivery_agent_count_key(job_id, agent_id)]) do
      {:ok, nil} -> {:ok, 0}
      {:ok, count} -> {:ok, Decoding.parse_redis_integer(count)}
      {:error, reason} -> {:error, Transport.format_reason(reason)}
    end
  end

  @doc false
  def expire_job_deliveries(job_id, ttl_seconds) do
    index_key = Keys.delivery_index_key(job_id)

    with {:ok, keys} <- Transport.command(["SMEMBERS", index_key]),
         # Protected projections and checkpoints retain their own replay TTL.
         keys <- Enum.reject(keys, &protected_retention_key?(job_id, &1)),
         commands <- Enum.map(keys, &["EXPIRE", &1, to_string(ttl_seconds)]),
         {:ok, _results} <- Transport.pipeline(commands) do
      :ok
    else
      {:error, reason} -> {:error, Transport.format_reason(reason)}
    end
  end

  @doc false
  def protected_retention_key?(job_id, candidate) do
    Enum.any?(["signals", "command", "commands", "checkpoint", "run_controls"], fn part ->
      prefix = RedisStore.storage_key(["job", job_id, part])
      candidate == prefix or String.starts_with?(candidate, prefix <> ":")
    end)
  end
end
