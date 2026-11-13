defmodule MirrorNeuron.ModelServices.Advertisement do
  @moduledoc "Normalizes explicit model service advertisements and owner identity."

  alias MirrorNeuron.ModelServices.Registration
  alias MirrorNeuron.ModelServices.Values

  @service_env_vars [
    "MN_NODE_SERVICES_JSON",
    "MN_MODEL_SERVICES_JSON"
  ]
  @model_env_vars [
    "MN_NODE_MODELS",
    "MN_NODE_RUNTIME_MODELS",
    "MN_DOCKER_MODEL_RUNNER_MODEL",
    "MN_LLM_MODEL_RUNNER_MODEL",
    "MN_LLM_RUNTIME_MODEL"
  ]
  @model_runner_endpoint_env_vars [
    "MN_DOCKER_MODEL_RUNNER_API_BASE",
    "MN_MODEL_RUNNER_API_BASE",
    "DOCKER_MODEL_RUNNER_API_BASE",
    "MODEL_RUNNER_HOST",
    "MN_LLM_API_BASE"
  ]
  @model_service_node_env "MN_MODEL_SERVICE_NODE_NAME"
  @network_advertise_host_env "MN_NETWORK_ADVERTISE_HOST"

  @doc false
  def env_model_refs(env \\ System.get_env()) when is_map(env) do
    @model_env_vars
    |> Enum.flat_map(fn name ->
      env
      |> Map.get(name)
      |> Values.split_env_list()
    end)
    |> Enum.uniq()
  end

  @doc false
  def service_instances_for_models(_model_refs, _node_name, _catalog \\ nil) do
    []
  end

  @doc false
  def service_instances_for_env(env, node_name, _catalog \\ nil) when is_map(env) do
    env
    |> explicit_service_instances(node_name)
    |> Enum.map(&with_runtime_health_check(&1, env))
  end

  @doc false
  def advertise_env_models(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_env(env, node_name)
    Registration.register_model_services(services, node_name)
  end

  @doc false
  def advertise_models(_model_refs, node_name \\ Node.self(), env \\ System.get_env())
      when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_env(env, node_name)
    Registration.register_model_services(services, node_name)
  end

  @doc false
  def persist_node_runtime_model(_model_ref, _env \\ System.get_env()), do: :ok

  @doc false
  def advertised_node_name(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    cond do
      explicit = Values.normalized_env(env, @model_service_node_env) ->
        explicit

      host = Values.normalized_env(env, @network_advertise_host_env) ->
        "#{Values.node_prefix(node_name)}@#{host}"

      true ->
        to_string(node_name)
    end
  end

  defp with_runtime_health_check(%{"name" => "docker-model-runner"} = service, env) do
    case Map.get(service, "address") || model_runner_endpoint(env) do
      nil ->
        service

      endpoint ->
        check = %{
          "name" => "docker-model-runner",
          "type" => "http",
          "url" => "#{String.trim_trailing(endpoint, "/")}/models",
          "timeout_ms" => 3_000,
          "failures_before_critical" => 1
        }

        service
        |> Map.put("address", endpoint)
        |> Map.update("checks", [check], fn checks -> [check | List.wrap(checks)] end)
    end
  end

  defp with_runtime_health_check(service, _env), do: service

  defp model_runner_endpoint(env) do
    @model_runner_endpoint_env_vars
    |> Enum.find_value(&Values.normalized_env(env, &1))
  end

  defp explicit_service_instances(env, node_name) do
    @service_env_vars
    |> Enum.flat_map(fn name ->
      env
      |> Map.get(name)
      |> decode_service_instances()
    end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {service, index} ->
      normalize_service_instance(service, node_name, index)
    end)
    |> Enum.uniq_by(&Map.get(&1, "id"))
  end

  defp decode_service_instances(nil), do: []

  defp decode_service_instances(""), do: []

  defp decode_service_instances(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decode_service_instances(decoded)
      {:error, _reason} -> []
    end
  end

  defp decode_service_instances(%{"services" => services}), do: decode_service_instances(services)

  defp decode_service_instances(%{} = services_by_name) do
    if service_instance_map?(services_by_name) do
      [services_by_name]
    else
      services_by_name
      |> Map.values()
      |> decode_service_instances()
    end
  end

  defp decode_service_instances(values) when is_list(values), do: Enum.filter(values, &is_map/1)

  defp decode_service_instances(_value), do: []

  defp service_instance_map?(value) when is_map(value) do
    Map.has_key?(value, "name") or Map.has_key?(value, :name) or Map.has_key?(value, "service") or
      Map.has_key?(value, :service)
  end

  defp normalize_service_instance(service, node_name, index) when is_map(service) do
    service = Values.stringify_keys(service)

    name =
      Values.normalized_map_value(service, "name") ||
        Values.normalized_map_value(service, "service")

    if name in [nil, ""] do
      []
    else
      node = Values.normalized_map_value(service, "node") || to_string(node_name)
      tags = Values.normalize_tags(Map.get(service, "tags", []))
      meta = Values.normalize_meta(Map.get(service, "meta", %{}))
      model_key = Values.service_model_key(service, meta, tags) || Integer.to_string(index)

      normalized =
        service
        |> Map.put("name", name)
        |> Map.put("node", node)
        |> Map.put("tags", tags)
        |> Map.put("meta", meta)
        |> Map.put_new("id", "#{node}:#{name}:#{model_key}")
        |> Map.put_new("provider", "mirror_neuron")
        |> Map.put_new("origin", "external")
        |> Map.put_new("status", "passing")
        |> Map.delete("service")

      [normalized]
    end
  end

  defp normalize_service_instance(_service, _node_name, _index), do: []
end
