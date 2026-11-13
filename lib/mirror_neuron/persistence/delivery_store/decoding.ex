defmodule MirrorNeuron.Persistence.DeliveryStore.Decoding do
  @moduledoc "Decodes Redis stream fields, receipts and integer counters."

  def parse_delivery_entries(entries) when is_list(entries) do
    Enum.map(entries, fn [stream_id, fields] ->
      fields = pairs_to_map(fields)

      %{
        stream_id: stream_id,
        message_id: fields["message_id"],
        payload: fields["payload"]
      }
    end)
  end

  def pairs_to_map(values) when is_list(values) do
    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  def parse_delivery_receipt(receipt) do
    receipt
    |> Map.update("attempts", 0, &parse_redis_integer/1)
    |> Map.update("deadline_ms", 0, &parse_redis_integer/1)
    |> Map.update("enqueued_at_ms", 0, &parse_redis_integer/1)
  end

  def parse_redis_integer(value) when is_integer(value), do: value

  def parse_redis_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  def parse_redis_integer(_value), do: 0
end
