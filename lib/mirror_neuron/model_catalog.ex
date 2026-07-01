defmodule MirrorNeuron.ModelCatalog do
  @moduledoc false

  alias MirrorNeuron.Config

  @model_runner_provider "docker_model_runner"
  @model_runner_service "docker-model-runner"

  def load_catalog(paths \\ nil) do
    builtin =
      builtin_catalog_path()
      |> read_catalog_entries()
      |> index_entries()

    paths =
      case paths do
        nil -> external_catalog_paths()
        values -> List.wrap(values)
      end

    Enum.reduce(paths, builtin, fn path, catalog ->
      path
      |> read_catalog_entries()
      |> Enum.reduce(catalog, fn entry, acc ->
        id = entry_id(entry)

        if id do
          Map.update(acc, id, entry, &deep_merge(&1, entry))
        else
          acc
        end
      end)
    end)
  end

  def list_entries(catalog \\ load_catalog()) when is_map(catalog) do
    catalog
    |> Map.values()
    |> Enum.sort_by(&(Map.get(&1, "id") || ""))
  end

  def resolve(model, catalog \\ load_catalog()) do
    requested = lookup_keys(model || "gemma4:e2b")

    catalog
    |> Map.values()
    |> Enum.find(fn entry ->
      entry
      |> lookup_values()
      |> Enum.any?(fn value ->
        value
        |> lookup_keys()
        |> Enum.any?(&MapSet.member?(requested, &1))
      end)
    end)
    |> case do
      nil -> {:error, :unknown_model}
      entry -> {:ok, entry}
    end
  end

  def resolve!(model, catalog \\ load_catalog()) do
    case resolve(model, catalog) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "unknown model #{inspect(model)}: #{reason}"
    end
  end

  def provider(entry) when is_map(entry) do
    entry
    |> Map.get("provider", @model_runner_provider)
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def docker_model_name(entry) when is_map(entry) do
    entry
    |> Map.get("model", Map.get(entry, "docker_model", ""))
    |> to_string()
    |> String.trim()
  end

  def model_id(entry) when is_map(entry), do: entry_id(entry)

  def service_requirement(entry) when is_map(entry) do
    %{
      "name" => service_name(entry),
      "tags" => service_tags(entry),
      "required" => true
    }
  end

  def service_instance(entry, node_name) when is_map(entry) do
    service = service_requirement(entry)
    node = to_string(node_name)

    service
    |> Map.put("id", "#{node}:#{service["name"]}:#{model_tag_value(entry)}")
    |> Map.put("node", node)
    |> Map.put("provider", "mirror_neuron")
    |> Map.put("origin", "external")
    |> Map.put("status", "passing")
    |> Map.put("meta", %{
      "model_id" => model_id(entry),
      "model" => docker_model_name(entry),
      "model_provider" => provider(entry)
    })
  end

  def service_name(entry) when is_map(entry) do
    case {provider(entry), Map.get(entry, "service_kind")} do
      {@model_runner_provider, _kind} -> @model_runner_service
      {"docker-model-runner", _kind} -> @model_runner_service
      {"dmr", _kind} -> @model_runner_service
      {"ollama", _kind} -> "ollama"
      {"nvidia_service", "speech_to_text"} -> "nvidia-asr"
      {"nvidia_service", "text_to_speech"} -> "nvidia-tts"
      {"nvidia-service", "speech_to_text"} -> "nvidia-asr"
      {"nvidia-service", "text_to_speech"} -> "nvidia-tts"
      {provider, _kind} -> String.replace(provider, "_", "-")
    end
  end

  def service_tags(entry) when is_map(entry) do
    provider = provider(entry)
    requirements = Map.get(entry, "requirements", %{})
    service_kind = Map.get(entry, "service_kind")

    model_tags =
      entry
      |> lookup_values()
      |> Enum.flat_map(&MapSet.to_list(lookup_keys(&1)))
      |> Enum.map(&"model:#{&1}")

    model_id_tags =
      [model_id(entry) || docker_model_name(entry)]
      |> Enum.flat_map(&MapSet.to_list(lookup_keys(&1)))
      |> Enum.map(&"model-id:#{&1}")

    base =
      [
        service_name(entry),
        provider,
        String.replace(provider, "_", "-"),
        "provider:#{String.replace(provider, "_", "-")}"
      ] ++ model_tags ++ model_id_tags

    accelerator =
      requirements
      |> Map.get("required_capabilities", [])
      |> List.wrap()
      |> Enum.map(&normalize_tag/1)
      |> then(fn capabilities ->
        if Enum.any?(capabilities, &String.contains?(&1, "nvidia")) do
          ["nvidia", "cuda"]
        else
          capabilities
        end
      end)

    kind_tags =
      case service_kind do
        "speech_to_text" -> ["nvidia", "speech-to-text"]
        "text_to_speech" -> ["nvidia", "text-to-speech"]
        _ -> []
      end

    (base ++ accelerator ++ kind_tags)
    |> Enum.map(&normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_tag(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp builtin_catalog_path do
    case :code.priv_dir(:mirror_neuron) do
      path when is_list(path) -> Path.join(to_string(path), "model_catalog.json")
      {:error, _reason} -> Path.expand("../../priv/model_catalog.json", __DIR__)
    end
  end

  defp external_catalog_paths do
    []
    |> maybe_cons(Config.optional_string("MN_MODEL_CATALOG_PATH", :model_catalog_path))
    |> Kernel.++([Path.join(mn_home(), "models/catalog.json")])
  end

  defp mn_home do
    Config.optional_string("MN_HOME", :home) || Path.expand("~/.mn")
  end

  defp maybe_cons(paths, nil), do: paths
  defp maybe_cons(paths, ""), do: paths
  defp maybe_cons(paths, path), do: paths ++ [Path.expand(path)]

  defp read_catalog_entries(path) do
    path = Path.expand(to_string(path))

    with true <- File.regular?(path),
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      decode_entries(decoded)
    else
      _ -> []
    end
  end

  defp decode_entries(%{"models" => models}) when is_list(models),
    do: Enum.filter(models, &is_map/1)

  defp decode_entries(entries) when is_list(entries), do: Enum.filter(entries, &is_map/1)

  defp decode_entries(map) when is_map(map) do
    if Enum.all?(map, fn {_key, value} -> is_map(value) end) do
      Enum.map(map, fn {id, entry} -> Map.put_new(entry, "id", id) end)
    else
      []
    end
  end

  defp decode_entries(_decoded), do: []

  defp index_entries(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      case entry_id(entry) do
        nil -> acc
        id -> Map.put(acc, id, entry)
      end
    end)
  end

  defp entry_id(entry) when is_map(entry) do
    entry
    |> Map.get("id")
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp lookup_values(entry) do
    [
      Map.get(entry, "id"),
      Map.get(entry, "model"),
      Map.get(entry, "api_model"),
      Map.get(entry, "docker_model")
      | List.wrap(Map.get(entry, "aliases", []))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp lookup_keys(value) do
    normalized = normalize_lookup(value)
    no_ai = strip_ai_prefix(normalized)
    no_latest = strip_latest_tag(normalized)
    no_ai_latest = no_ai |> strip_latest_tag()

    [normalized, no_ai, no_latest, no_ai_latest]
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_lookup(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp strip_ai_prefix("ai/" <> value), do: value
  defp strip_ai_prefix(value), do: value

  defp strip_latest_tag(value) do
    if String.ends_with?(value, ":latest") do
      String.replace_suffix(value, ":latest", "")
    else
      value
    end
  end

  defp model_tag_value(entry), do: docker_model_name(entry) |> normalize_tag()

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp deep_merge(_left, right), do: right
end
