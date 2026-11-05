defmodule MirrorNeuron.Cluster.RuntimeStatus do
  @moduledoc false

  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, NodeAdapter, NodeState}
  alias Mirrorneuron.Cluster.V1.GetNodeRuntimeStatusRequest

  # Dependencies keep routing tests independent of Redis and live peers.
  def fetch(node_name, opts \\ []) do
    adapter = Keyword.get(opts, :node_adapter, NodeAdapter)
    states = Keyword.get(opts, :node_state, NodeState)
    registry = Keyword.get(opts, :federation_registry, FederationRegistry)
    client = Keyword.get(opts, :federation_client, FederationClient)
    local = to_string(adapter.self())
    node_name = String.trim(node_name)

    cond do
      node_name == "" ->
        fail!(:invalid_argument, "node_name is required")

      node_name == local ->
        local_snapshot(states, node_name, local)

      Keyword.get(opts, :hop, 0) > 0 ->
        fail!(
          :failed_precondition,
          "MN_FEDERATION_LOOP: forwarded request cannot be forwarded again"
        )

      match?({:ok, _}, registry.fetch(node_name)) ->
        response =
          client.call_cluster(node_name, :get_node_runtime_status, %GetNodeRuntimeStatusRequest{
            node_name: node_name,
            version: 1
          })

        case Jason.decode(response.resource_json) do
          {:ok, %{"name" => ^node_name, "runtime_status" => status} = node} when is_map(status) ->
            # Only the requested owner's public snapshot crosses this boundary.
            node
            |> Map.take(["name", "grpc_host", "status", "runtime_status"])
            |> Map.put("self", false)

          _ ->
            fail!(
              :failed_precondition,
              "peer returned an invalid runtime status identity or snapshot"
            )
        end

      Enum.any?(adapter.list(), &(to_string(&1) == node_name)) ->
        local_snapshot(states, node_name, local)

      true ->
        fail!(:not_found, "runtime node is not connected")
    end
  end

  def snapshot(state, local_node) do
    node_name = to_string(Map.get(state, "node") || "")
    host = Map.get(state, "grpc_host") || Map.get(state, "address") || node_host(node_name)

    %{
      "name" => node_name,
      "grpc_host" => host,
      "status" => Map.get(state, "status", "healthy"),
      "self" => node_name == local_node,
      "runtime_status" => normalize_model_inventory(Map.get(state, "runtime_status", %{}))
    }
  end

  # Redis Lua cjson round-trips an empty array as an empty object. Restore this
  # schema-declared list on both aggregate and owner reads, including old data.
  # NodeState rejects non-list inventories before new publications are stored.
  defp normalize_model_inventory(%{"models" => %{"status" => %{"models" => models}}} = domains)
       when is_map(models) and map_size(models) == 0 do
    put_in(domains, ["models", "status", "models"], [])
  end

  defp normalize_model_inventory(domains), do: domains

  defp local_snapshot(states, node_name, local) do
    case states.fetch(node_name) do
      {:ok, state} when is_map(state) -> snapshot(state, local)
      _ -> fail!(:not_found, "runtime node snapshot is unavailable")
    end
  end

  defp node_host(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [_name, host] -> host
      _ -> nil
    end
  end

  defp fail!(status, message), do: raise(GRPC.RPCError, status: status, message: message)
end
