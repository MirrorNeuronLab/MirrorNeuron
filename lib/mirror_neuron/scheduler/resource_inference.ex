defmodule MirrorNeuron.Scheduler.ResourceInference do
  @moduledoc false

  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.ResourceSpec

  @model_env_keys [
    "MN_LLM_RUNTIME_MODEL",
    "MN_LLM_MODEL",
    "LITELLM_MODEL",
    "OLLAMA_MODEL",
    "VL_MODEL_NAME"
  ]

  @service_model_providers [
    "docker_model_runner",
    "docker-model-runner",
    "dmr",
    "ollama",
    "nvidia_service",
    "nvidia-service"
  ]

  def infer(manifest, node, resource_request, constraints, requires_services) do
    catalog = ModelCatalog.load_catalog()

    models =
      manifest
      |> model_refs_for_node(node, catalog)
      |> resolve_model_entries(catalog)

    Enum.reduce(
      models,
      %{
        "resource_request" => resource_request,
        "constraints" => constraints,
        "requires_services" => requires_services,
        "placement_requirements" => %{"models" => []}
      },
      &apply_model_requirement/2
    )
    |> dedupe_state()
  end

  defp model_refs_for_node(manifest, node, catalog) do
    node_refs = node_model_refs(node)

    if node_refs != [] do
      node_refs
    else
      manifest_refs = manifest_model_refs(manifest, catalog)

      if manifest_refs != [] and receives_manifest_models?(manifest, node) do
        manifest_refs
      else
        []
      end
    end
  end

  defp resolve_model_entries(model_refs, catalog) do
    model_refs
    |> Enum.uniq_by(&(to_string(&1) |> String.downcase()))
    |> Enum.flat_map(fn model_ref ->
      case ModelCatalog.resolve(model_ref, catalog) do
        {:ok, entry} -> [entry]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(&(ModelCatalog.model_id(&1) || ModelCatalog.docker_model_name(&1)))
  end

  defp apply_model_requirement(entry, state) do
    requirements = Map.get(entry, "requirements", %{})
    required_capabilities = required_capabilities(requirements)
    min_vram_mb = gb_to_mb(number_value(Map.get(requirements, "min_vram_gb")))
    min_unified_mb = gb_to_mb(number_value(Map.get(requirements, "min_unified_memory_gb")))

    state
    |> maybe_add_gpu_request(entry, min_vram_mb, min_unified_mb, required_capabilities)
    |> maybe_add_capability_constraint(required_capabilities)
    |> maybe_add_service_requirement(entry)
    |> add_model_summary(entry, min_vram_mb, min_unified_mb, required_capabilities)
  end

  defp maybe_add_gpu_request(state, entry, min_vram_mb, min_unified_mb, required_capabilities) do
    if needs_gpu?(entry, min_vram_mb, min_unified_mb, required_capabilities) and
         not service_backed_model?(entry) do
      request =
        %{
          "kind" => "gpu",
          "type" =>
            if(nvidia_required?(entry, required_capabilities), do: "nvidia/gpu", else: "gpu"),
          "count" => 1,
          "vendor" => if(nvidia_required?(entry, required_capabilities), do: "nvidia", else: nil),
          "driver" => if(nvidia_required?(entry, required_capabilities), do: "cuda", else: nil),
          "min_memory_mb" => min_vram_mb || min_unified_mb,
          "capabilities" => [],
          "ids" => []
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      resource_request =
        state["resource_request"]
        |> ResourceSpec.add_gpu_need(1)
        |> merge_device_request(request)

      Map.put(state, "resource_request", resource_request)
    else
      state
    end
  end

  defp maybe_add_capability_constraint(state, []), do: state

  defp maybe_add_capability_constraint(state, required_capabilities) do
    constraint = %{
      "attribute" => "capabilities",
      "operator" => "contains_any",
      "value" => required_capabilities
    }

    Map.update(state, "constraints", [constraint], &(&1 ++ [constraint]))
  end

  defp maybe_add_service_requirement(state, entry) do
    if ModelCatalog.provider(entry) in @service_model_providers do
      requirement = ModelCatalog.service_requirement(entry)
      Map.update(state, "requires_services", [requirement], &(&1 ++ [requirement]))
    else
      state
    end
  end

  defp add_model_summary(state, entry, min_vram_mb, min_unified_mb, required_capabilities) do
    summary = %{
      "id" => ModelCatalog.model_id(entry),
      "model" => ModelCatalog.docker_model_name(entry),
      "provider" => ModelCatalog.provider(entry),
      "service" => ModelCatalog.service_requirement(entry),
      "min_vram_mb" => min_vram_mb,
      "min_unified_memory_mb" => min_unified_mb,
      "required_capabilities" => required_capabilities
    }

    update_in(state, ["placement_requirements", "models"], &((&1 || []) ++ [summary]))
  end

  defp dedupe_state(state) do
    state
    |> Map.update!("constraints", &uniq_maps/1)
    |> Map.update!("requires_services", &uniq_maps/1)
  end

  defp merge_device_request(%{"devices" => devices} = resource_request, request) do
    {gpu_devices, other_devices} = Enum.split_with(devices || [], &gpu_device?/1)

    devices =
      case gpu_devices do
        [] -> [request | other_devices]
        [first | rest] -> [merge_gpu_device(first, request) | rest ++ other_devices]
      end

    Map.put(resource_request, "devices", devices)
  end

  defp merge_device_request(resource_request, request),
    do: Map.put(resource_request, "devices", [request])

  defp merge_gpu_device(existing, inferred) do
    existing
    |> put_missing("kind", Map.get(inferred, "kind"))
    |> put_missing("type", Map.get(inferred, "type"))
    |> put_missing("vendor", Map.get(inferred, "vendor"))
    |> put_missing("driver", Map.get(inferred, "driver"))
    |> Map.update("count", Map.get(inferred, "count", 1), fn count ->
      max(number_value(count) || 0, number_value(Map.get(inferred, "count")) || 0) |> trunc()
    end)
    |> Map.update("min_memory_mb", Map.get(inferred, "min_memory_mb"), fn min_memory ->
      max(number_value(min_memory) || 0, number_value(Map.get(inferred, "min_memory_mb")) || 0)
    end)
    |> Map.update("capabilities", Map.get(inferred, "capabilities", []), fn capabilities ->
      (List.wrap(capabilities) ++ List.wrap(Map.get(inferred, "capabilities", [])))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
    end)
  end

  defp put_missing(map, _key, nil), do: map
  defp put_missing(map, key, value), do: Map.put_new(map, key, value)

  defp gpu_device?(device) do
    kind = String.downcase(to_string(Map.get(device, "kind") || ""))
    type = String.downcase(to_string(Map.get(device, "type") || ""))
    kind == "gpu" or String.contains?(type, "gpu")
  end

  defp needs_gpu?(_entry, min_vram_mb, min_unified_mb, required_capabilities) do
    is_number(min_vram_mb) or is_number(min_unified_mb) or required_capabilities != []
  end

  defp service_backed_model?(entry) do
    ModelCatalog.provider(entry) in @service_model_providers
  end

  defp nvidia_required?(entry, required_capabilities) do
    provider = ModelCatalog.provider(entry)

    provider in ["nvidia_service", "nvidia-service"] or
      Enum.any?(required_capabilities, &String.contains?(&1, "nvidia"))
  end

  defp required_capabilities(requirements) when is_map(requirements) do
    requirements
    |> Map.get("required_capabilities", [])
    |> List.wrap()
    |> Enum.map(&ModelCatalog.normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp required_capabilities(_requirements), do: []

  defp manifest_model_refs(manifest, catalog) do
    manifest
    |> map_get("runtime")
    |> map_get("models")
    |> model_entries_from_runtime(catalog)
  end

  defp model_entries_from_runtime(models, catalog) when is_map(models) do
    models
    |> Enum.flat_map(fn {_name, entry} -> runtime_model_ref(entry, catalog) end)
    |> Enum.uniq()
  end

  defp model_entries_from_runtime(_models, _catalog), do: []

  defp runtime_model_ref(entry, catalog) when is_map(entry) do
    ref =
      map_get(entry, "runtime_model") ||
        map_get(entry, "model") ||
        map_get(entry, "api_model")

    provider = map_get(entry, "provider") |> to_string() |> String.downcase()

    cond do
      blank?(ref) ->
        []

      provider in @service_model_providers ->
        [ref]

      match?({:ok, _entry}, ModelCatalog.resolve(ref, catalog)) ->
        [ref]

      true ->
        []
    end
  end

  defp runtime_model_ref(_entry, _catalog), do: []

  defp receives_manifest_models?(manifest, node) do
    hinted_nodes =
      manifest
      |> map_get("nodes")
      |> List.wrap()
      |> Enum.filter(&node_has_runtime_hint?/1)

    if hinted_nodes != [] do
      Enum.any?(hinted_nodes, &(map_get(&1, "node_id") == map_get(node, "node_id")))
    else
      model_candidate_node?(node)
    end
  end

  defp model_candidate_node?(node) do
    agent_type =
      node
      |> map_get("agent_type")
      |> to_string()
      |> String.downcase()

    agent_type not in ["router", "aggregator", "sensor"]
  end

  defp node_has_runtime_hint?(node) do
    resource_map = map_get(node, "resources") || %{}

    resource_request =
      resource_map
      |> ResourceSpec.normalize_request()

    ResourceSpec.scheduling_devices(resource_request) != [] or
      requires_services?(node) or
      node_model_refs(node) != []
  end

  defp requires_services?(node) do
    value =
      cond do
        is_map(node) and Map.has_key?(node, :requires_services) ->
          Map.get(node, :requires_services)

        is_map(node) and Map.has_key?(node, "requires_services") ->
          Map.get(node, "requires_services")

        true ->
          []
      end

    List.wrap(value) != []
  end

  defp node_model_refs(node) do
    config = map_get(node, "config") || %{}
    env = map_get(config, "environment") || %{}

    []
    |> Kernel.++(config_model_refs(config))
    |> Kernel.++(env_model_refs(env))
    |> Kernel.++(blueprint_config_model_refs(env))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp config_model_refs(config) when is_map(config) do
    direct =
      [
        map_get(config, "runtime_model"),
        map_get(config, "model"),
        map_get(config, "llm_model")
      ]

    llm_refs =
      config
      |> map_get("llm")
      |> llm_model_refs()

    direct ++ llm_refs
  end

  defp config_model_refs(_config), do: []

  defp env_model_refs(env) when is_map(env) do
    Enum.map(@model_env_keys, &map_get(env, &1))
  end

  defp env_model_refs(_env), do: []

  defp blueprint_config_model_refs(env) when is_map(env) do
    env
    |> map_get("MN_BLUEPRINT_CONFIG_JSON")
    |> case do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{} = config} -> config_model_refs(config)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp blueprint_config_model_refs(_env), do: []

  defp llm_model_refs(%{"configs" => configs}) when is_map(configs) do
    Enum.flat_map(configs, fn {_name, config} -> config_model_refs(config) end)
  end

  defp llm_model_refs(%{} = llm), do: config_model_refs(Map.delete(llm, "llm"))
  defp llm_model_refs(_llm), do: []

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp uniq_maps(values) do
    values
    |> List.wrap()
    |> Enum.reduce([], fn value, acc ->
      key = :erlang.term_to_binary(value)

      if Enum.any?(acc, fn {existing_key, _value} -> existing_key == key end) do
        acc
      else
        [{key, value} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp gb_to_mb(nil), do: nil
  defp gb_to_mb(value) when is_number(value), do: value * 1024

  defp number_value(value) when is_integer(value), do: value
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_value), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      existing_atom_value(map, key)
    end
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    atom = String.to_existing_atom(key)
    if Map.has_key?(map, atom), do: Map.get(map, atom)
  rescue
    ArgumentError -> nil
  end
end
