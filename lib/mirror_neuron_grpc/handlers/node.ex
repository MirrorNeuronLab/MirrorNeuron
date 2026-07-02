defmodule MirrorNeuron.Grpc.Handlers.Node do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Cluster.JoinClaim
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Grpc.Handlers.Support

  alias Mirrorneuron.Cluster.V1.{
    AddNodeResponse,
    CancelNodeDrainResponse,
    DrainNodeResponse,
    GetNodeDrainStatusResponse,
    ReconcileNodeResponse,
    RemoveNodeResponse,
    SetNodeMaintenanceResponse
  }

  def add_node(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("AddNode")
    token = Map.get(request, :token, "")
    maybe_set_remote_cookie(request.node_name, token)

    case MirrorNeuron.add_node(request.node_name) do
      {:ok, %{status: status}} ->
        confirm_remote_join_claim(request.node_name)
        sync_remote_cookie_with_cluster(request.node_name, token)
        advertise_remote_model_services(request.node_name)

        %AddNodeResponse{
          node_name: request.node_name,
          status: status,
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
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
        NodeAdapter.disconnect(node)
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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RemoveNode")

    case mark_node_operator_disconnected(request.node_name) do
      {:ok, remote_node} ->
        clear_remote_join_claim(request.node_name)
        _ = NodeAdapter.disconnect(remote_node)

        %RemoveNodeResponse{
          node_name: request.node_name,
          status: "disconnected",
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  def reconcile_node(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ReconcileNode")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  def drain_node(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DrainNode")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  def cancel_node_drain(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CancelNodeDrain")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  def set_node_maintenance(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SetNodeMaintenance")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  def get_node_drain_status(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetNodeDrainStatus")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  defp maybe_set_remote_cookie(node_name, token)
       when is_binary(node_name) and is_binary(token) and token != "" do
    with {:ok, node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name),
         {:ok, cookie} <-
           cookie_from_token(token) |> MirrorNeuron.SafeAccess.nonempty_binary_to_atom() do
      NodeAdapter.set_cookie(node, cookie)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_set_remote_cookie(_node_name, _token), do: :ok

  defp sync_remote_cookie_with_cluster(node_name, token)
       when is_binary(node_name) and is_binary(token) and node_name != "" and token != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, remote_node} ->
        cookie = cookie_from_token(token)

        peer_nodes =
          [NodeAdapter.self() | NodeAdapter.list()]
          |> Enum.uniq()
          |> Enum.reject(&(&1 == remote_node))

        peer_nodes
        |> Enum.reject(&(&1 == NodeAdapter.self()))
        |> Enum.each(fn peer ->
          _ =
            NodeAdapter.rpc_call(
              peer,
              MirrorNeuron.Grpc.ClusterServer,
              :set_peer_cookie,
              [node_name, cookie],
              2_000
            )
        end)

        Enum.each(peer_nodes, fn peer ->
          _ =
            NodeAdapter.rpc_call(
              remote_node,
              MirrorNeuron.Grpc.ClusterServer,
              :set_peer_cookie,
              [Atom.to_string(peer), cookie],
              2_000
            )
        end)

        _ =
          NodeAdapter.rpc_call(
            remote_node,
            MirrorNeuron.Grpc.ClusterServer,
            :connect_peer,
            [Atom.to_string(NodeAdapter.self())],
            2_000
          )

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp sync_remote_cookie_with_cluster(_node_name, _token), do: :ok

  defp confirm_remote_join_claim(node_name) when is_binary(node_name) and node_name != "" do
    with {:ok, remote_node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      _ =
        NodeAdapter.rpc_call(
          remote_node,
          MirrorNeuron.Grpc.ClusterServer,
          :confirm_join_claim,
          [Atom.to_string(NodeAdapter.self())],
          2_000
        )

      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  defp confirm_remote_join_claim(_node_name), do: :ok

  defp advertise_remote_model_services(node_name) when is_binary(node_name) and node_name != "" do
    with {:ok, remote_node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name),
         %{} = info <-
           NodeAdapter.rpc_call(
             remote_node,
             MirrorNeuron.Grpc.ClusterServer,
             :node_advertisement_info,
             [],
             2_000
           ) do
      services = services_from_node_info(info, node_name)

      if services != [] do
        _ = service_registry().register_many(services)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp advertise_remote_model_services(_node_name), do: :ok

  defp services_from_node_info(info, fallback_node_name) when is_map(info) do
    explicit_services =
      List.wrap(Map.get(info, "services")) ++ List.wrap(Map.get(info, :services))

    node_name = Map.get(info, "node_name") || Map.get(info, :node_name) || fallback_node_name

    runtime_model_services =
      (List.wrap(Map.get(info, "runtime_models")) ++ List.wrap(Map.get(info, :runtime_models)))
      |> Enum.flat_map(&runtime_model_service(&1, node_name))

    (explicit_services ++ runtime_model_services)
    |> Enum.filter(&is_map/1)
  end

  defp runtime_model_service(model, node_name) when is_binary(model) do
    model = String.trim(model)
    node_name = Support.blank_to_nil(to_string(node_name || ""))

    if model == "" or is_nil(node_name) do
      []
    else
      canonical_model = canonical_runtime_model(model)

      [
        %{
          "id" => "#{node_name}:docker-model-runner:#{model}",
          "name" => "docker-model-runner",
          "node" => node_name,
          "provider" => "docker_model_runner",
          "origin" => "runtime_model_advertisement",
          "status" => "passing",
          "tags" =>
            [
              "docker-model-runner",
              "model:#{model}",
              "model-id:#{model}",
              "model:#{canonical_model}",
              "model-id:#{canonical_model}"
            ]
            |> Enum.uniq(),
          "meta" => %{"model" => canonical_model, "model_id" => model}
        }
      ]
    end
  end

  defp runtime_model_service(_model, _node_name), do: []

  defp canonical_runtime_model("nemotron3"), do: "ai/nemotron3:latest"
  defp canonical_runtime_model(model), do: model

  defp service_registry do
    Application.get_env(:mirror_neuron, :service_registry, MirrorNeuron.ServiceRegistry)
  end

  defp clear_remote_join_claim(node_name) when is_binary(node_name) and node_name != "" do
    with {:ok, remote_node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      _ =
        NodeAdapter.rpc_call(
          remote_node,
          MirrorNeuron.Grpc.ClusterServer,
          :clear_join_claim,
          [Atom.to_string(NodeAdapter.self())],
          2_000
        )

      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  defp clear_remote_join_claim(_node_name), do: :ok

  defp mark_node_operator_disconnected(node_name) when is_binary(node_name) do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, remote_node} ->
        case NodeState.mark(node_name, "disconnected", %{
               "operator_disconnect" => true,
               "scheduling_eligible" => false,
               "reason" => "operator requested disconnect"
             }) do
          {:ok, _state} -> {:ok, remote_node}
          {:error, reason} -> {:error, to_string(reason)}
        end

      {:error, _reason} ->
        {:error, "invalid node name #{inspect(node_name)}"}
    end
  end

  defp mark_node_operator_disconnected(node_name),
    do: {:error, "invalid node name #{inspect(node_name)}"}

  defp cookie_from_token(token) do
    :crypto.hash(:sha256, "mirror-neuron:cookie:#{token}")
    |> Base.encode16(case: :lower)
  end
end
