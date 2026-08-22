defmodule MirrorNeuron.Grpc.Handlers.Node do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Cluster.JoinClaim
  alias MirrorNeuron.Cluster.FederationRegistry
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Grpc.Handlers.Support

  alias Mirrorneuron.Cluster.V1.{
    CancelNodeDrainResponse,
    DrainNodeResponse,
    GetNodeDrainStatusResponse,
    ReconcileNodeResponse,
    RemoveNodeResponse,
    RegisterFederatedPeerResponse,
    GetFederatedPeerResponse,
    RemoveFederatedPeerResponse,
    SetNodeMaintenanceResponse
  }

  def add_node(_request, _stream) do
    raise GRPC.RPCError,
      status: GRPC.Status.failed_precondition(),
      message: "AddNode is a legacy distributed-cluster RPC; use RegisterFederatedPeer"
  end

  def register_federated_peer(request, _stream) do
    with {:ok, peer_info} <- decode_peer_info(request.peer_info_json),
         {:ok, peer, status} <-
           FederationRegistry.register(request.node_name, peer_info, request.peer_auth_token) do
      _ = disconnect_peer(request.node_name)
      _ = confirm_join_claim(request.node_name)
      maybe_start_local_leader()

      %RegisterFederatedPeerResponse{
        node_name: request.node_name,
        status: status,
        peer_json: Support.versioned_json(peer),
        local_peer_auth_token: MirrorNeuron.Grpc.Tokens.peer_token(request.node_name),
        version: @interface_version
      }
    else
      {:error, reason} -> raise_federation_error!(reason)
    end
  end

  def get_federated_peer(request, _stream) do
    case FederationRegistry.public_fetch(request.node_name) do
      {:ok, peer} ->
        %GetFederatedPeerResponse{
          peer_json: Support.versioned_json(peer),
          version: @interface_version
        }

      {:error, :peer_not_found} ->
        raise GRPC.RPCError,
          status: GRPC.Status.not_found(),
          message: "federated peer was not found"
    end
  end

  def remove_federated_peer(request, _stream) do
    case FederationRegistry.remove(request.node_name) do
      {:ok, status} ->
        _ = disconnect_peer(request.node_name)
        _ = clear_join_claim(request.node_name)

        %RemoveFederatedPeerResponse{
          node_name: request.node_name,
          status: status,
          version: @interface_version
        }

      {:error, reason} ->
        raise_federation_error!(reason)
    end
  end

  @doc false
  def set_peer_cookie(node_name, cookie_text)
      when is_binary(node_name) and is_binary(cookie_text) and
             node_name != "" and cookie_text != "" do
    with {:ok, node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name),
         {:ok, cookie} <- MirrorNeuron.SafeAccess.nonempty_binary_to_atom(cookie_text) do
      NodeAdapter.set_cookie(node, cookie)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def connect_peer(node_name) when is_binary(node_name) and node_name != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, node} ->
        NodeAdapter.connect(node)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def connect_peer(_node_name), do: :ok

  @doc false
  def disconnect_peer(node_name) when is_binary(node_name) and node_name != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, node} ->
        if node in NodeAdapter.list(), do: NodeAdapter.disconnect(node)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def disconnect_peer(_node_name), do: :ok

  @doc false
  def disconnect_peers(node_names) when is_list(node_names) do
    Enum.each(node_names, &disconnect_peer/1)
    :ok
  end

  @doc false
  def confirm_join_claim(owner_node_name) do
    JoinClaim.confirm(owner_node_name)
  end

  @doc false
  def clear_join_claim(owner_node_name) do
    JoinClaim.clear(owner_node_name)
  end

  def remove_node(request, _stream) do
    case FederationRegistry.remove(request.node_name) do
      {:ok, status} ->
        _ = disconnect_peer(request.node_name)
        _ = clear_join_claim(request.node_name)

        %RemoveNodeResponse{
          node_name: request.node_name,
          status: status,
          version: @interface_version
        }

      {:error, reason} ->
        raise_federation_error!(reason)
    end
  end

  defp decode_peer_info(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, info} when is_map(info) -> {:ok, info}
      _ -> {:error, :invalid_peer_info}
    end
  end

  defp decode_peer_info(_json), do: {:error, :invalid_peer_info}

  defp raise_federation_error!(:peer_identity_conflict) do
    raise GRPC.RPCError,
      status: GRPC.Status.already_exists(),
      message: "federated peer identity conflicts with an existing registration"
  end

  defp raise_federation_error!(:shared_coordination_store) do
    raise GRPC.RPCError,
      status: GRPC.Status.failed_precondition(),
      message: "federated peers must use distinct coordination stores"
  end

  defp raise_federation_error!(reason) do
    raise GRPC.RPCError,
      status: GRPC.Status.invalid_argument(),
      message: "federated peer registration failed: #{reason}"
  end

  defp maybe_start_local_leader do
    if Process.whereis(MirrorNeuron.Cluster.Leader) do
      send(MirrorNeuron.Cluster.Leader, :campaign)
    end

    :ok
  end

  def reconcile_node(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ReconcileNode")

    opts =
      [
        reason: Support.blank_to_nil(request.reason),
        dry_run: request.dry_run
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.reconcile_node(request.node_name, opts) do
      {:ok, result} ->
        %ReconcileNodeResponse{
          result_json: Support.versioned_json(result),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def drain_node(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DrainNode")

    opts =
      [
        reason: Support.blank_to_nil(request.reason),
        dry_run: request.dry_run,
        deadline_ms: if(request.deadline_ms > 0, do: request.deadline_ms, else: nil),
        ignore_system_jobs: request.ignore_system_jobs
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.drain_node(request.node_name, opts) do
      {:ok, result} ->
        %DrainNodeResponse{
          result_json: Support.versioned_json(result),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def cancel_node_drain(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CancelNodeDrain")

    opts =
      [
        reason: Support.blank_to_nil(request.reason),
        mark_eligible: request.mark_eligible
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.cancel_node_drain(request.node_name, opts) do
      {:ok, result} ->
        %CancelNodeDrainResponse{
          result_json: Support.versioned_json(result),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def set_node_maintenance(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SetNodeMaintenance")

    opts =
      [reason: Support.blank_to_nil(request.reason)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.set_node_maintenance(request.node_name, request.enabled, opts) do
      {:ok, result} ->
        %SetNodeMaintenanceResponse{
          result_json: Support.versioned_json(result),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def get_node_drain_status(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetNodeDrainStatus")

    case MirrorNeuron.node_drain_status(request.node_name) do
      {:ok, result} ->
        %GetNodeDrainStatusResponse{
          result_json: Support.versioned_json(result),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end
end
