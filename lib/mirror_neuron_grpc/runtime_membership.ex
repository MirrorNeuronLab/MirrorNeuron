defmodule MirrorNeuron.Grpc.RuntimeMembership do
  @moduledoc false
  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, NodeAdapter}
  alias MirrorNeuron.Grpc.Handlers.Node, as: NodeHandler
  alias Mirrorneuron.Cluster.V1.RemoveFederatedPeerRequest
  alias Mirrorneuron.Runtime.V1.{RuntimeReply, RuntimeControlService.Stub}

  def remove(request) do
    with {:ok, %{"node_name" => name}} when is_binary(name) and name != "" <-
           Jason.decode(request.arguments_json) do
      if name == to_string(NodeAdapter.self()) do
        detach()
      else
        forwarded = %{
          request
          | action: "node.detach",
            arguments_json: Jason.encode!(%{"_owner_node" => name})
        }

        {target, forwarded, metadata} = MirrorNeuron.Grpc.RuntimeControlRoute.resolve(forwarded)

        case GRPC.Stub.connect(target, timeout: 5_000) do
          {:ok, channel} ->
            try do
              case Stub.execute(channel, forwarded, timeout: 30_000, metadata: metadata) do
                {:ok, reply} -> reply
                {:error, error} -> raise error
              end
            after
              GRPC.Stub.disconnect(channel)
            end

          {:error, error} ->
            raise error
        end
      end
    else
      _ -> error("MN_NODE_INVALID", "A node name is required.", 422)
    end
  end

  # This executes on the node being removed, against its authoritative admission
  # ledger. It never stops a service, cancels a job, or erases runtime data.
  def detach(options \\ []) do
    name = Keyword.get_lazy(options, :node, fn -> to_string(NodeAdapter.self()) end)
    drain = Keyword.get(options, :drain, &MirrorNeuron.node_drain_status/1)
    admission = Keyword.get(options, :admission, &MirrorNeuron.Runtime.NodeAdmission.snapshot/0)
    peers = Keyword.get(options, :peers, &FederationRegistry.list/0)
    disconnect = Keyword.get(options, :disconnect, &disconnect/2)

    with {:ok, state} <- drain.(name),
         :ok <- drained(state),
         {:ok, ledger} <- admission.(),
         :ok <- idle(ledger) do
      Enum.each(peers.(), fn peer -> disconnect.(name, peer["node_name"]) end)

      %RuntimeReply{
        version: 1,
        status: 200,
        value_json: Jason.encode!(%{"node_name" => name, "status" => "removed"})
      }
    else
      {:error, :drain_required} ->
        error(
          "MN_NODE_DRAIN_REQUIRED",
          "Drain the node and wait for completion before removing it.",
          409,
          "Run mn node drain #{name}, then inspect mn node show #{name}."
        )

      {:error, :admission_busy} ->
        error(
          "MN_NODE_BUSY",
          "The node still owns admitted or queued work.",
          409,
          "Wait for work to finish or explicitly manage it before retrying removal."
        )

      _ ->
        error(
          "MN_NODE_STATE_UNAVAILABLE",
          "Cannot verify the node's drain and admission state.",
          503
        )
    end
  end

  defp drained(%{"scheduling_eligible" => false, "drain" => %{"status" => "complete"}}), do: :ok
  defp drained(_), do: {:error, :drain_required}

  defp idle(%{"reservations" => reservations, "queue" => [], "deferred" => []})
       when is_map(reservations) and map_size(reservations) == 0, do: :ok

  defp idle(_), do: {:error, :admission_busy}

  defp disconnect(local, peer) do
    # Keep the local link if the peer has not acknowledged removal. A retry can
    # complete a partial detach without guessing whether active work was lost.
    FederationClient.call_cluster(peer, :remove_federated_peer, %RemoveFederatedPeerRequest{
      node_name: local,
      version: 1
    })

    NodeHandler.remove_federated_peer(
      %RemoveFederatedPeerRequest{node_name: peer, version: 1},
      nil
    )
  end

  defp error(code, message, status, hint \\ nil) do
    %RuntimeReply{
      version: 1,
      status: status,
      error_json: Jason.encode!(%{"code" => code, "message" => message, "hint" => hint})
    }
  end
end
