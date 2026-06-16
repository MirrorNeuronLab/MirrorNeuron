defmodule MirrorNeuron.ModelServices do
  @moduledoc false

  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.ServiceRegistry

  @active_node_statuses ["healthy", "joining"]
  @model_env_vars [
    "MN_NODE_MODELS",
    "MN_NODE_RUNTIME_MODELS",
    "MN_DOCKER_MODEL_RUNNER_MODEL",
    "MN_LLM_MODEL_RUNNER_MODEL"
  ]
  @model_runner_endpoint_env_vars [
    "MN_DOCKER_MODEL_RUNNER_API_BASE",
    "MN_MODEL_RUNNER_API_BASE",
    "DOCKER_MODEL_RUNNER_API_BASE",
    "MODEL_RUNNER_HOST"
  ]
  @model_service_node_env "MN_MODEL_SERVICE_NODE_NAME"
  @network_advertise_host_env "MN_NETWORK_ADVERTISE_HOST"
  @default_node_name "mirror_neuron"

  def env_model_refs(env \\ System.get_env()) when is_map(env) do
    @model_env_vars
    |> Enum.flat_map(fn name ->
      env
      |> Map.get(name)
      |> split_env_list()
    end)
    |> Enum.uniq()
  end

  def service_instances_for_models(model_refs, node_name, catalog \\ ModelCatalog.load_catalog()) do
    model_refs
    |> List.wrap()
    |> Enum.flat_map(fn model_ref ->
      case ModelCatalog.resolve(model_ref, catalog) do
        {:ok, entry} -> [entry]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(&(ModelCatalog.model_id(&1) || ModelCatalog.docker_model_name(&1)))
    |> Enum.map(&ModelCatalog.service_instance(&1, node_name))
  end

  def service_instances_for_env(env, node_name, catalog \\ ModelCatalog.load_catalog())
      when is_map(env) do
    env
    |> env_model_refs()
    |> service_instances_for_models(node_name, catalog)
    |> Enum.map(&with_runtime_health_check(&1, env))
  end

  def advertise_env_models(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_env(env, node_name)

    case services do
      [] ->
        :ok

      services ->
        with {:ok, registered} <- ServiceRegistry.register_many(services) do
          prune_stale_model_services(registered, node_name)
          {:ok, registered}
        end
    end
  rescue
    _ -> :ok
  end

  @doc false
  def advertised_node_name(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    cond do
      explicit = normalized_env(env, @model_service_node_env) ->
        explicit

      host = normalized_env(env, @network_advertise_host_env) ->
        "#{node_prefix(node_name)}@#{host}"

      true ->
        to_string(node_name)
    end
  end

  defp with_runtime_health_check(%{"name" => "docker-model-runner"} = service, env) do
    case model_runner_endpoint(env) do
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
    |> Enum.find_value(&normalized_env(env, &1))
  end

  defp prune_stale_model_services(services, node_name) do
    model_ids =
      services
      |> Enum.map(&model_service_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if MapSet.size(model_ids) == 0 do
      :ok
    else
      active_nodes = active_node_names()

      case ServiceRegistry.list() do
        {:ok, existing} ->
          existing
          |> Enum.filter(&stale_model_service?(&1, node_name, model_ids, active_nodes))
          |> Enum.each(fn service -> ServiceRegistry.deregister_service(service["id"]) end)

          :ok

        _ ->
          :ok
      end
    end
  end

  defp stale_model_service?(service, current_node, model_ids, active_nodes) do
    service_node = Map.get(service, "node")

    Map.get(service, "name") == "docker-model-runner" and
      service_node != current_node and
      not MapSet.member?(active_nodes, service_node) and
      MapSet.member?(model_ids, model_service_id(service))
  end

  defp model_service_id(service) do
    get_in(service, ["meta", "model_id"]) ||
      service
      |> Map.get("tags", [])
      |> List.wrap()
      |> Enum.find_value(fn tag ->
        case String.split(to_string(tag), "model-id:", parts: 2) do
          ["", value] -> value
          _ -> nil
        end
      end)
  end

  defp active_node_names do
    MirrorNeuron.Cluster.NodeState.list()
    |> Enum.filter(&(Map.get(&1, "status") in @active_node_statuses))
    |> Enum.map(&Map.get(&1, "node", Map.get(&1, "name")))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  defp split_env_list(nil), do: []

  defp split_env_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalized_env(env, key) do
    env
    |> Map.get(key)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp node_prefix(node_name) do
    node_name
    |> to_string()
    |> String.split("@", parts: 2)
    |> case do
      [prefix, _host] when prefix != "" -> prefix
      _ -> @default_node_name
    end
  end
end
