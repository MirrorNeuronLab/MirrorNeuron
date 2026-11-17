defmodule MirrorNeuron.Grpc.RuntimeMembership do
  @moduledoc false
  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, NodeAdapter}
  alias MirrorNeuron.Grpc.Handlers.Node, as: NodeHandler
  alias MirrorNeuron.Runtime.{AdmissionLedger, QueueReconciliation}
  alias Mirrorneuron.Cluster.V1.{RemoveFederatedPeerRequest, RemoveFederatedPeerResponse}
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
    verify_work = Keyword.get(options, :verify_work, &QueueReconciliation.import_existing/0)
    admission = Keyword.get(options, :admission, &MirrorNeuron.Runtime.NodeAdmission.snapshot/0)
    peers = Keyword.get(options, :peers, &FederationRegistry.list/0)
    disconnect = Keyword.get(options, :disconnect, &disconnect/2)

    result =
      with :ok <- verify_work.() do
        AdmissionLedger.with_membership_gate(fn ->
          with {:ok, ledger} <- admission.(),
               :ok <- idle(ledger) do
            Enum.reduce_while(peers.(), :ok, fn peer, :ok ->
              case disconnect.(name, peer["node_name"]) do
                :ok -> {:cont, :ok}
                _ -> {:halt, {:error, :disconnect_unconfirmed}}
              end
            end)
          end
        end)
      end

    case result do
      :ok ->
        %RuntimeReply{
          version: 1,
          status: 200,
          value_json: Jason.encode!(%{"node_name" => name, "status" => "removed"})
        }

      {:error, reason} when reason in [:admission_busy, :missing_node_reservation] ->
        error(
          "MN_NODE_BUSY",
          "The node still owns admitted or queued work.",
          409,
          "Wait for work to finish or explicitly manage it before retrying removal."
        )

      {:error, :disconnect_unconfirmed} ->
        removal_unconfirmed()

      _ ->
        error(
          "MN_NODE_STATE_UNAVAILABLE",
          "Cannot verify the node's admission state.",
          503
        )
    end
  rescue
    _error in GRPC.RPCError -> removal_unconfirmed()
  end

  defp idle(%{
         "reservations" => reservations,
         "queue" => queue,
         "deferred" => deferred,
         "requests" => requests
       })
       when is_map(reservations) and is_list(queue) and is_list(deferred) and is_map(requests) do
    if map_size(reservations) == 0 and queue == [] and deferred == [] and map_size(requests) == 0,
      do: :ok,
      else: {:error, :admission_busy}
  end

  defp idle(_), do: {:error, :invalid_admission_state}

  defp disconnect(local, peer) do
    # Keep the local link if the peer has not acknowledged removal. A retry can
    # complete a partial detach without guessing whether active work was lost.
    response =
      FederationClient.call_cluster(peer, :remove_federated_peer, %RemoveFederatedPeerRequest{
        node_name: local,
        version: 1
      })

    with :ok <- removed(response, local) do
      NodeHandler.remove_federated_peer(
        %RemoveFederatedPeerRequest{node_name: peer, version: 1},
        nil
      )
      |> removed(peer)
    end
  end

  defp removed(%RemoveFederatedPeerResponse{node_name: name, status: status, version: 1}, name)
       when status in ["removed", "not_found"], do: :ok

  defp removed(_, _), do: {:error, :disconnect_unconfirmed}

  defp removal_unconfirmed do
    error(
      "MN_NODE_REMOVAL_UNCONFIRMED",
      "Could not confirm removal on every connected computer.",
      503,
      "Restore connectivity and retry node removal. The runtime and its data remain intact."
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
