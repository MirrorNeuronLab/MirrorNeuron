defmodule MirrorNeuron.ModelServices do
  @moduledoc false

  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.ServiceRegistry

  @model_env_vars ["MN_NODE_MODELS", "MN_NODE_RUNTIME_MODELS"]
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
        {:ok, entry} -> [ModelCatalog.service_instance(entry, node_name)]
        {:error, _reason} -> []
      end
    end)
  end

  def advertise_env_models(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_models(env_model_refs(env), node_name)

    case services do
      [] -> :ok
      services -> ServiceRegistry.register_many(services)
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
