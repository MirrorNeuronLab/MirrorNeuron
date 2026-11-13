defmodule MirrorNeuron.Runtime.WorkflowLedger.Values do
  @moduledoc "Normalizes ledger values and computes deadline timestamps."

  alias MirrorNeuron.Runtime

  def without_actions({state, events}), do: {state, events, []}

  def normalize_event_type(type) when is_atom(type), do: Atom.to_string(type)

  def normalize_event_type(type), do: to_string(type)

  def expired?(nil, _now), do: false

  def expired?(iso, now) do
    case {parse_iso(iso), parse_iso(now)} do
      {{:ok, deadline}, {:ok, current}} -> DateTime.compare(current, deadline) != :lt
      _ -> false
    end
  end

  defp iso_after_seconds(now, seconds), do: iso_after_ms(now, positive_int(seconds, 0) * 1000)

  def iso_after_seconds_if_configured(_now, nil), do: nil

  def iso_after_seconds_if_configured(now, seconds), do: iso_after_seconds(now, seconds)

  def iso_after_ms_if_configured(_now, nil), do: nil

  def iso_after_ms_if_configured(now, ms), do: iso_after_ms(now, ms)

  def iso_after_ms(now, ms) do
    case parse_iso(now) do
      {:ok, datetime} ->
        datetime
        |> DateTime.add(positive_int(ms, 0), :millisecond)
        |> DateTime.truncate(:millisecond)
        |> DateTime.to_iso8601()

      _ ->
        Runtime.timestamp()
    end
  end

  defp parse_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_iso(_iso), do: :error

  def positive_int(value, _default) when is_integer(value) and value > 0, do: value

  def positive_int(value, _default) when is_float(value) and value > 0, do: trunc(value)

  def positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  def positive_int(_value, default), do: default

  def positive_number(value, _default) when is_integer(value) and value > 0, do: value

  def positive_number(value, _default) when is_float(value) and value > 0, do: value

  def positive_number(_value, default), do: default

  def stringify(value) when is_binary(value), do: value

  def stringify(value), do: inspect(value)

  def stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  def stringify_map(_map), do: %{}

  def unique_id do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
