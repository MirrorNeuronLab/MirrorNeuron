defmodule MirrorNeuron.ModelServices do
  @moduledoc false

  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.ServiceRegistry

  @model_env_vars ["MN_NODE_MODELS", "MN_NODE_RUNTIME_MODELS"]

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

  def advertise_env_models(node_name \\ Node.self()) do
    node_name = to_string(node_name)
    services = service_instances_for_models(env_model_refs(), node_name)

    case services do
      [] -> :ok
      services -> ServiceRegistry.register_many(services)
    end
  rescue
    _ -> :ok
  end

  defp split_env_list(nil), do: []

  defp split_env_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
