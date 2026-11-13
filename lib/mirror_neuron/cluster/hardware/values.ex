defmodule MirrorNeuron.Cluster.Hardware.Values do
  @moduledoc "Hardware unit parsing and conservative numeric normalization."

  alias MirrorNeuron.Config

  def cpu_model do
    blank_to_nil(Config.optional_string("MN_NODE_CPU_MODEL", :node_cpu_model))
  rescue
    _ -> nil
  end

  def memory_pressure(total_bytes, available_bytes) do
    used_bytes = max(total_bytes - available_bytes, 0)

    %{
      total_bytes: total_bytes,
      total_mb: Float.round(total_bytes / (1024 * 1024), 2),
      available_bytes: available_bytes,
      available_mb: Float.round(available_bytes / (1024 * 1024), 2),
      used_bytes: used_bytes,
      used_mb: Float.round(used_bytes / (1024 * 1024), 2),
      used_ratio: ratio(used_bytes, total_bytes)
    }
  end

  def normalize_capability(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "" or String.downcase(value) == "[n/a]", do: nil, else: value
  end

  def version_after(nil, _label), do: nil

  def version_after(value, label) do
    label = Regex.escape(to_string(label))

    case Regex.run(~r/#{label}\s*[:=\- ]*\s*([0-9]+(?:\.[0-9]+)*)/i, to_string(value)) do
      [_match, version] -> version
      _ -> nil
    end
  end

  def parse_float(nil), do: nil

  def parse_float(value) do
    case Float.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  def parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  def parse_gpu_count(nil), do: nil

  def parse_gpu_count(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {count, ""} when count >= 0 -> count
      _ -> nil
    end
  end

  def truthy?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]

  def truthy?(_value), do: false

  def falsey?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["0", "false", "no", "off"]

  def falsey?(_value), do: false

  def host_name do
    case :inet.gethostname() do
      {:ok, hostname} -> hostname |> to_string() |> String.split(".", parts: 2) |> List.first()
      _ -> "unknown-host"
    end
  end

  def number_value(value) when is_integer(value), do: value

  def number_value(value) when is_float(value), do: value

  def number_value(value) when is_binary(value), do: parse_float(value)

  def number_value(_value), do: nil

  def map_get(map, key) when is_map(map), do: MirrorNeuron.SafeAccess.map_get(map, key)

  def map_get(_map, _key), do: nil

  def ratio(nil, _denominator), do: nil

  def ratio(_numerator, nil), do: nil

  def ratio(_numerator, 0), do: nil

  def ratio(numerator, denominator) when is_number(numerator) and is_number(denominator) do
    Float.round(numerator / denominator, 4)
  end
end
