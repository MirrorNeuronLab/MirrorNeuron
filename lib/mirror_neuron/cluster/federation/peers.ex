defmodule MirrorNeuron.Cluster.FederationRegistry.Peers do
  @moduledoc "Validates peer identity, registers local advertisements and removes peers."

  alias MirrorNeuron.Cluster.FederationRegistry.Availability
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Cluster.FederationRegistry.Storage
  alias MirrorNeuron.Cluster.FederationRegistry.Values

  def register(node_name, peer_info, peer_auth_token)
      when is_binary(node_name) and is_map(peer_info) and is_binary(peer_auth_token) do
    node_name = String.trim(node_name)
    token = String.trim(peer_auth_token)

    with :ok <- require_peer_name(node_name),
         :ok <- require_peer_token(token),
         :ok <- reject_self(node_name),
         {:ok, local_store} <- Values.coordination_store().coordination_store_status(),
         :ok <- require_distinct_store(local_store, peer_info) do
      peer =
        peer_info
        |> Values.stringify_keys()
        |> Map.put("node_name", node_name)
        |> Map.put("connection_mode", "federated")
        |> Map.put("peer_auth_token", token)
        |> Map.put("registered_at", Values.timestamp())

      Storage.update_registry(fn peers ->
        case Map.get(peers, node_name) do
          nil -> {:ok, Map.put(peers, node_name, peer), peer, "registered"}
          existing -> register_existing(peers, node_name, existing, peer)
        end
      end)
      |> case do
        {:ok, saved, status} ->
          :ok = advertise_peer(saved)
          {:ok, public_peer(saved), status}

        error ->
          error
      end
    end
  end

  def register(_node_name, _peer_info, _peer_auth_token), do: {:error, :invalid_peer}

  def fetch(node_name) do
    case Map.fetch(Storage.read_registry(), to_string(node_name)) do
      {:ok, peer} -> {:ok, peer}
      :error -> {:error, :peer_not_found}
    end
  end

  def public_fetch(node_name) do
    case fetch(node_name) do
      {:ok, peer} -> {:ok, public_peer(peer)}
      error -> error
    end
  end

  def list, do: Storage.read_registry() |> Map.values()

  def public_list, do: Enum.map(list(), &public_peer/1)

  def ready?, do: map_size(Storage.read_registry()) > 0

  def remove(node_name) do
    node_name = to_string(node_name) |> String.trim()

    result =
      Storage.update_registry(fn peers ->
        if Map.has_key?(peers, node_name) do
          {:ok, Map.delete(peers, node_name), nil, "removed"}
        else
          {:ok, peers, nil, "not_found"}
        end
      end)

    _ =
      Availability.mark_peer_state(node_name, "disconnected", %{
        "connection_mode" => "federated",
        "operator_disconnect" => true,
        "scheduling_eligible" => false,
        "job_owner_eligible" => false,
        "peer_available" => false
      })

    case result do
      {:ok, _peer, status} ->
        _ = Values.projection_store().delete_federation_projections(node_name)
        {:ok, status}

      error ->
        error
    end
  end

  defp register_existing(peers, node_name, existing, peer) do
    if peer_identity(existing) == peer_identity(peer) and
         MirrorNeuron.Grpc.Tokens.secure_compare(
           Map.get(existing, "peer_auth_token", ""),
           Map.get(peer, "peer_auth_token", "")
         ) do
      merged =
        existing
        |> Map.merge(peer)
        |> Map.drop(["job_projections", "run_projections"])

      {:ok, Map.put(peers, node_name, merged), merged, "already_registered"}
    else
      {:error, :peer_identity_conflict}
    end
  end

  defp peer_identity(peer) do
    {Map.get(peer, "node_name"), get_in(peer, ["coordination_store", "identity"])}
  end

  def require_peer_name(""), do: {:error, :missing_peer_name}

  def require_peer_name("nonode@nohost"), do: {:error, :invalid_peer_name}

  def require_peer_name(_node_name), do: :ok

  def require_job_id(""), do: {:error, :missing_job_id}

  def require_job_id(_job_id), do: :ok

  defp require_peer_token(""), do: {:error, :missing_peer_auth_token}

  defp require_peer_token(_token), do: :ok

  defp reject_self(node_name) do
    if node_name == to_string(NodeAdapter.self()), do: {:error, :cannot_federate_self}, else: :ok
  end

  defp require_distinct_store(local_store, peer_info) do
    local_identity =
      to_string(Map.get(local_store, "identity") || Map.get(local_store, :identity) || "")

    remote_store =
      Map.get(peer_info, "coordination_store") || Map.get(peer_info, :coordination_store) || %{}

    remote_identity =
      to_string(Map.get(remote_store, "identity") || Map.get(remote_store, :identity) || "")

    cond do
      local_identity == "" or remote_identity == "" -> {:error, :coordination_store_unavailable}
      local_identity == remote_identity -> {:error, :shared_coordination_store}
      true -> :ok
    end
  end

  defp advertise_peer(peer) do
    public = public_peer(peer)

    case Availability.mark_peer_state(Map.fetch!(public, "node_name"), "healthy", %{
           "connection_mode" => "federated",
           "operator_disconnect" => false,
           "scheduling_eligible" => false,
           "local_scheduler_eligible" => Map.get(public, "scheduling_eligible", true),
           "job_owner_eligible" => true,
           "peer_available" => true,
           "admission" => Map.get(public, "admission", %{}),
           "grpc_host" => Map.get(public, "grpc_host"),
           "grpc_port" => Map.get(public, "grpc_port"),
           "litellm" => Map.get(public, "litellm", %{}),
           "coordination_store" => Map.get(public, "coordination_store", %{}),
           "hardware" => Map.get(public, "hardware", %{}),
           "native_sdk_grpc" => Map.get(public, "native_sdk_grpc", %{}),
           "display_name" => Map.get(public, "display_name"),
           "hostname" => Map.get(public, "hostname"),
           "runtime_models" => Map.get(public, "runtime_models", []),
           "services" => Map.get(public, "services", [])
         }) do
      {:ok, _state} -> :ok
      error -> error
    end
  end

  def public_peer(peer) do
    peer
    |> Map.drop([
      "peer_auth_token",
      "job_projections",
      "run_projections",
      "archive_tombstones",
      "delete_tombstones"
    ])
    |> Map.put("connection_mode", "federated")
  end
end
