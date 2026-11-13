defmodule MirrorNeuron.ModelServices.Registration do
  @moduledoc "Registers model services and prunes only stale equivalent advertisements."

  alias MirrorNeuron.ServiceRegistry

  @active_node_statuses ["healthy", "joining"]

  def register_model_services(services, node_name) do
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
end
