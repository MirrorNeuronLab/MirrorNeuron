defmodule MirrorNeuron.Cluster.FederatedServices do
  @moduledoc false

  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry}
  alias MirrorNeuron.ServiceRegistry

  def list(opts \\ [], dependencies \\ []) do
    local_registry = Keyword.get(dependencies, :local_registry, ServiceRegistry)
    federation_registry = Keyword.get(dependencies, :federation_registry, FederationRegistry)
    federation_client = Keyword.get(dependencies, :federation_client, FederationClient)

    with {:ok, local_services} <- local_registry.list(opts) do
      remote_services =
        federation_registry.list()
        |> Enum.flat_map(fn peer ->
          node_name = Map.get(peer, "node_name")

          if query_peer?(node_name, opts) do
            list_peer_services(federation_client, node_name, opts)
          else
            []
          end
        end)

      {:ok, merge(local_services, remote_services)}
    end
  end

  @doc false
  def merge(local_services, remote_services) do
    (local_services ++ remote_services)
    |> Enum.reduce({MapSet.new(), []}, fn service, {seen, services} ->
      key = service_key(service)

      if MapSet.member?(seen, key) do
        {seen, services}
      else
        {MapSet.put(seen, key), [service | services]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp query_peer?(node_name, opts) do
    case Keyword.get(opts, :node) do
      node when node in [nil, ""] -> true
      node -> to_string(node) == to_string(node_name)
    end
  end

  defp list_peer_services(client, node_name, opts) do
    client.list_services(node_name, opts)
  rescue
    _error -> []
  end

  defp service_key(service) do
    Map.get(service, "id") ||
      {Map.get(service, "node"), Map.get(service, "job_id"), Map.get(service, "agent_id"),
       Map.get(service, "name")}
  end
end
