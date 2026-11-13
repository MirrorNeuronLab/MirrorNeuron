defmodule MirrorNeuron.Persistence.DeliveryStore.Reading do
  @moduledoc "Claims ordered stream entries and fences attempts before returning work."

  alias MirrorNeuron.Persistence.DeliveryStore.Decoding
  alias MirrorNeuron.Persistence.DeliveryStore.Keys
  alias MirrorNeuron.Persistence.DeliveryStore.Transport

  @delivery_consumer_group "mirror_neuron_agents"

  @doc false
  def read_deliveries(job_id, agent_id, consumer, opts) do
    stream_key = Keys.delivery_stream_key(job_id, agent_id)
    lease_ms = Keyword.fetch!(opts, :lease_ms)
    max_attempts = Keyword.fetch!(opts, :max_attempts)
    now_ms = Keyword.fetch!(opts, :now_ms)
    count = Keyword.get(opts, :count, 1)

    with :ok <-
           maybe_ensure_delivery_group(
             stream_key,
             Keyword.fetch!(opts, :stream_ttl_seconds),
             Keyword.get(opts, :ensure_group, true)
           ),
         {:ok, entries} <- delivery_entries(stream_key, consumer, lease_ms, count, opts) do
      entries
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case prepare_delivery(job_id, agent_id, consumer, entry, now_ms, max_attempts) do
          {:ok, delivery} -> {:cont, {:ok, [delivery | acc]}}
          {:discard, discard} -> {:cont, {:ok, [discard | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, deliveries} -> {:ok, Enum.reverse(deliveries)}
        error -> error
      end
    end
  end

  defp delivery_entries(stream_key, consumer, lease_ms, count, opts) do
    if Keyword.get(opts, :strict_fifo, false) do
      # Select only the oldest pending delivery. A deferred head must not be
      # bypassed by new work in the same lane. Selection/claim is atomic.
      script = """
      local pending = redis.call("xpending", KEYS[1], ARGV[1], "-", "+", 1)
      if #pending > 0 then
        if pending[1][3] < tonumber(ARGV[3]) then return {} end
        return redis.call("xclaim", KEYS[1], ARGV[1], ARGV[2], ARGV[3], pending[1][1])
      end
      local fresh = redis.call("xreadgroup", "GROUP", ARGV[1], ARGV[2], "COUNT", 1, "STREAMS", KEYS[1], ">")
      if not fresh then return {} end
      return fresh[1][2]
      """

      case Transport.command([
             "EVAL",
             script,
             "1",
             stream_key,
             @delivery_consumer_group,
             consumer,
             to_string(lease_ms)
           ]) do
        {:ok, entries} -> {:ok, Decoding.parse_delivery_entries(entries)}
        error -> error
      end
    else
      with {:ok, claimed} <-
             maybe_claim_stale_deliveries(
               stream_key,
               consumer,
               lease_ms,
               count,
               Keyword.get(opts, :claim_stale, true)
             ),
           {:ok, entries} <- read_new_deliveries(stream_key, consumer, count - length(claimed)) do
        {:ok, claimed ++ entries}
      end
    end
  end

  defp ensure_delivery_group(stream_key, stream_ttl_seconds) do
    case Transport.command([
           "XGROUP",
           "CREATE",
           stream_key,
           @delivery_consumer_group,
           "0",
           "MKSTREAM"
         ]) do
      {:ok, "OK"} ->
        case Transport.command(["EXPIRE", stream_key, to_string(stream_ttl_seconds)]) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, Transport.format_reason(reason)}
        end

      {:error, %Redix.Error{message: message}} when is_binary(message) ->
        if String.contains?(message, "BUSYGROUP"), do: :ok, else: {:error, message}

      {:error, reason} ->
        {:error, Transport.format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_group_result, other}}
    end
  end

  defp maybe_ensure_delivery_group(stream_key, stream_ttl_seconds, true),
    do: ensure_delivery_group(stream_key, stream_ttl_seconds)

  defp maybe_ensure_delivery_group(_stream_key, _stream_ttl_seconds, false), do: :ok

  defp claim_stale_deliveries(stream_key, consumer, lease_ms, count) when count > 0 do
    case Transport.command([
           "XAUTOCLAIM",
           stream_key,
           @delivery_consumer_group,
           consumer,
           to_string(lease_ms),
           "0-0",
           "COUNT",
           to_string(count)
         ]) do
      {:ok, [_next_start, entries | _deleted]} -> {:ok, Decoding.parse_delivery_entries(entries)}
      {:error, reason} -> {:error, Transport.format_reason(reason)}
      other -> {:error, {:unexpected_delivery_claim_result, other}}
    end
  end

  defp claim_stale_deliveries(_stream_key, _consumer, _lease_ms, _count), do: {:ok, []}

  defp maybe_claim_stale_deliveries(stream_key, consumer, lease_ms, count, true),
    do: claim_stale_deliveries(stream_key, consumer, lease_ms, count)

  defp maybe_claim_stale_deliveries(_stream_key, _consumer, _lease_ms, _count, false),
    do: {:ok, []}

  defp read_new_deliveries(stream_key, consumer, count) when count > 0 do
    case Transport.command([
           "XREADGROUP",
           "GROUP",
           @delivery_consumer_group,
           consumer,
           "COUNT",
           to_string(count),
           "STREAMS",
           stream_key,
           ">"
         ]) do
      {:ok, nil} -> {:ok, []}
      {:ok, [[^stream_key, entries]]} -> {:ok, Decoding.parse_delivery_entries(entries)}
      {:error, reason} -> {:error, Transport.format_reason(reason)}
      other -> {:error, {:unexpected_delivery_read_result, other}}
    end
  end

  defp read_new_deliveries(_stream_key, _consumer, _count), do: {:ok, []}

  defp prepare_delivery(job_id, agent_id, consumer, entry, now_ms, max_attempts) do
    receipt_key = Keys.delivery_receipt_key(job_id, agent_id, entry.message_id)

    script = """
    local pending = redis.call('xpending', KEYS[2], ARGV[4], ARGV[5], ARGV[5], 1)
    if #pending == 0 or pending[1][2] ~= ARGV[3] then return {'owner_changed', '0'} end
    if redis.call("exists", KEYS[1]) == 0 then
      return {"missing", "0"}
    end
    local status = redis.call("hget", KEYS[1], "status") or "unknown"
    if status == "acked" or status == "dead_letter" then
      return {status, redis.call("hget", KEYS[1], "attempts") or "0"}
    end
    local deadline_ms = tonumber(redis.call("hget", KEYS[1], "deadline_ms") or "0")
    if deadline_ms > 0 and tonumber(ARGV[1]) > deadline_ms then
      return {"expired", redis.call("hget", KEYS[1], "attempts") or "0"}
    end
    local attempts = redis.call("hincrby", KEYS[1], "attempts", 1)
    if attempts > tonumber(ARGV[2]) then
      return {"attempts_exhausted", tostring(attempts)}
    end
    redis.call("hset", KEYS[1], "status", "processing", "consumer", ARGV[3])
    return {"deliver", tostring(attempts)}
    """

    case Transport.command([
           "EVAL",
           script,
           "2",
           receipt_key,
           Keys.delivery_stream_key(job_id, agent_id),
           to_string(now_ms),
           to_string(max_attempts),
           consumer,
           @delivery_consumer_group,
           entry.stream_id
         ]) do
      {:ok, ["owner_changed", _]} ->
        {:error, :delivery_owner_changed}

      {:ok, ["deliver", attempts]} ->
        case Jason.decode(entry.payload) do
          {:ok, message} ->
            {:ok,
             Map.merge(entry, %{
               message: message,
               attempt: Decoding.parse_redis_integer(attempts)
             })}

          {:error, reason} ->
            {:discard, Map.merge(entry, %{discard_reason: {:invalid_payload, reason}})}
        end

      {:ok, [reason, attempts]}
      when reason in ["missing", "acked", "dead_letter", "expired", "attempts_exhausted"] ->
        {:discard,
         Map.merge(entry, %{
           discard_reason: String.to_atom(reason),
           message:
             case Jason.decode(entry.payload) do
               {:ok, value} -> value
               _ -> %{}
             end,
           attempt: Decoding.parse_redis_integer(attempts)
         })}

      {:error, reason} ->
        {:error, Transport.format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_prepare_result, other}}
    end
  end
end
