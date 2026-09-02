defmodule MirrorNeuron.Artifacts.BlobRef do
  @moduledoc false

  @sha256_re ~r/^[a-f0-9]{64}$/

  def collect(value) do
    value
    |> do_collect([])
    |> Enum.reverse()
    |> Enum.map(&normalize/1)
    |> Enum.filter(&valid?/1)
    |> Enum.uniq_by(fn ref -> {ref["sha256"], ref["payload_path"]} end)
  end

  def normalize(%{} = ref) do
    ref = stringify_map(ref)

    %{
      "type" => "blob_ref",
      "sha256" => normalize_sha(Map.get(ref, "sha256")),
      "size_bytes" => integer_value(Map.get(ref, "size_bytes") || Map.get(ref, "bytes")),
      "media_type" => blank_to_nil(Map.get(ref, "media_type") || Map.get(ref, "mime_type")),
      "logical_name" => blank_to_nil(Map.get(ref, "logical_name") || Map.get(ref, "name")),
      "scope" => blank_to_nil(Map.get(ref, "scope")) || "job",
      "payload_path" =>
        normalize_payload_path(Map.get(ref, "payload_path") || Map.get(ref, "path")),
      "locations" => normalize_locations(Map.get(ref, "locations", []))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  def normalize(_ref), do: %{}

  def valid?(%{"sha256" => sha}) when is_binary(sha), do: Regex.match?(@sha256_re, sha)
  def valid?(_ref), do: false

  def refs_for_payload_prefix(refs, prefix) do
    prefix = normalize_payload_path(prefix)

    normalized_refs =
      refs
      |> List.wrap()
      |> Enum.map(&normalize/1)
      |> Enum.filter(&valid?/1)

    Enum.filter(normalized_refs, fn ref ->
      payload_path = Map.get(ref, "payload_path")

      is_binary(payload_path) and
        (is_nil(prefix) or
           payload_path == prefix or
           String.starts_with?(payload_path, prefix <> "/"))
    end)
  end

  def payload_suffix(%{"payload_path" => payload_path}, prefix) do
    prefix = normalize_payload_path(prefix)
    payload_path = normalize_payload_path(payload_path)

    cond do
      is_nil(payload_path) ->
        nil

      is_nil(prefix) ->
        payload_path

      payload_path == prefix ->
        ""

      String.starts_with?(payload_path, prefix <> "/") ->
        String.replace_prefix(payload_path, prefix <> "/", "")

      true ->
        nil
    end
  end

  defp do_collect(%{} = value, acc) do
    acc =
      if blob_ref_map?(value) do
        [value | acc]
      else
        acc
      end

    Enum.reduce(value, acc, fn {_key, child}, child_acc -> do_collect(child, child_acc) end)
  end

  defp do_collect(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &do_collect/2)
  end

  defp do_collect(_value, acc), do: acc

  defp blob_ref_map?(%{} = value) do
    type = Map.get(value, "type") || Map.get(value, :type)
    sha = Map.get(value, "sha256") || Map.get(value, :sha256)

    to_string(type) == "blob_ref" or
      (is_binary(sha) and Regex.match?(@sha256_re, normalize_sha(sha)))
  end

  defp normalize_locations(locations) when is_list(locations) do
    locations
    |> Enum.map(&normalize_location/1)
    |> Enum.filter(&(map_size(&1) > 0))
  end

  defp normalize_locations(location) when is_map(location), do: [normalize_location(location)]
  defp normalize_locations(_locations), do: []

  defp normalize_location(location) when is_map(location) do
    location
    |> stringify_map()
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_location(_location), do: %{}

  def normalize_payload_path(nil), do: nil

  def normalize_payload_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.trim()
    |> String.trim_leading("/")
    |> case do
      "" -> nil
      "." -> nil
      value -> value
    end
  end

  defp normalize_sha(nil), do: nil
  defp normalize_sha(value), do: value |> to_string() |> String.downcase()

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
