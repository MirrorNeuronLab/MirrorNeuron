# Service-only binding: all message types are imported from the existing generated
# cluster bindings. The public declaration lives in proto/interactions.proto.
defmodule MirrorNeuron.Grpc.InteractionService do
  use GRPC.Service, name: "mirrorneuron.interactions.v1.InteractionService", protoc_gen_elixir_version: "0.16.0"
  rpc :Command, Mirrorneuron.Cluster.V1.SetResourceRequest, Mirrorneuron.Cluster.V1.GetResourceResponse
  rpc :Watch, Mirrorneuron.Cluster.V1.SetResourceRequest, stream(Mirrorneuron.Cluster.V1.GetResourceResponse)
end

defmodule MirrorNeuron.Grpc.InteractionStub do
  use GRPC.Stub, service: MirrorNeuron.Grpc.InteractionService
end

defmodule MirrorNeuron.Grpc.InteractionServer do
  use GRPC.Server, service: MirrorNeuron.Grpc.InteractionService
  alias MirrorNeuron.Runtime.Interactions
  alias MirrorNeuron.Persistence.InteractionStore
  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, FederatedJobRouting, NodeAdapter}
  alias MirrorNeuron.Grpc.Auth
  alias Mirrorneuron.Cluster.V1.{GetResourceResponse, SetResourceRequest}

  def command(request, stream) do
    authorize!(stream)
    input = decode!(request.resource_json)
    if Auth.federation_hop(stream) > 0, do: reply(Interactions.command(input)), else: reply(route(input))
  end

  defp route(%{"op" => "snapshot"}) do
    with {:ok, local} <- Interactions.command(%{"op" => "snapshot"}) do
      snapshots = [{local_node(), local} | Enum.map(peers(), fn node -> {node, remote(node, %{"op" => "snapshot"})} end)]
      {:ok, %{"items" => Enum.flat_map(snapshots, fn {_, value} -> value["items"] end),
        "cursor" => encode_cursor(Map.new(snapshots, fn {node, value} -> {node, value["cursor"]} end)),
        "capability" => "mn.interaction.v1"}}
    end
  end
  defp route(%{"op" => "create", "record" => record} = input) do
    scope = Map.get(record, "scope", %{})
    owner = if scope["execution_id"], do: FederatedJobRouting.run_owner(scope["execution_id"]), else: FederatedJobRouting.job_owner(scope["job_id"] || "")
    if owner, do: {:ok, remote(owner, input)}, else: Interactions.command(input)
  end
  defp route(%{"id" => id} = input) do
    case InteractionStore.get(id) do
      {:ok, _} -> Interactions.command(input)
      {:error, "not_found"} ->
        owner = Enum.find(peers(), fn node -> remote(node, %{"op" => "get", "id" => id}, true)["error"] != "not_found" end)
        if owner, do: {:ok, remote(owner, input)}, else: {:error, "not_found"}
      error -> error
    end
  end
  defp route(input), do: Interactions.command(input)

  def watch(request, stream) do
    authorize!(stream)
    input = decode!(request.resource_json)
    if Auth.federation_hop(stream) > 0 do
      local_watch(input["cursor"] || "0-0", fn event -> GRPC.Server.send_reply(stream, reply({:ok, event})) end)
    else
      cursors = decode_cursor!(input["cursor"])
      nodes = [local_node() | peers()]
      unless Enum.sort(Map.keys(cursors)) == Enum.sort(nodes), do: raise(GRPC.RPCError, status: :failed_precondition, message: "cursor_expired")
      parent = self()
      children = Enum.map(nodes, fn node ->
        spawn_monitor(fn ->
          send_event = fn event -> send(parent, {:interaction_event, node, event}) end
          if node == local_node() do
            local_watch(cursors[node], send_event)
          else
            FederationClient.interaction_events(node, request(%{"cursor" => cursors[node]}), fn response ->
              send_event.(Jason.decode!(response.resource_json))
            end)
          end
        end)
      end)
      try do
        multiplex(stream, cursors, nodes)
      after
        Enum.each(children, fn {pid, reference} -> Process.demonitor(reference, [:flush]); Process.exit(pid, :kill) end)
      end
    end
    stream
  end

  defp multiplex(stream, cursors, nodes) do
    if elem(Process.info(self(), :message_queue_len), 1) > 512 do
      GRPC.Server.send_reply(stream, reply({:error, "cursor_expired"}))
    else
      receive do
        {:interaction_event, node, %{"id" => cursor} = event} ->
          next = Map.put(cursors, node, cursor)
          GRPC.Server.send_reply(stream, reply({:ok, Map.put(event, "id", encode_cursor(next))}))
          multiplex(stream, next, nodes)
        {:interaction_event, _, %{"error" => code}} -> GRPC.Server.send_reply(stream, reply({:error, code}))
        {:interaction_event, _, _} ->
          if Enum.sort(nodes) != Enum.sort([local_node() | peers()]) do
            GRPC.Server.send_reply(stream, reply({:error, "cursor_expired"}))
          else
            GRPC.Server.send_reply(stream, reply({:ok, %{"type" => "heartbeat"}}))
            multiplex(stream, cursors, nodes)
          end
        {:DOWN, _, :process, _, _} -> GRPC.Server.send_reply(stream, reply({:error, "stream_disconnected"}))
      after
        30_000 -> GRPC.Server.send_reply(stream, reply({:error, "stream_disconnected"}))
      end
    end
  end

  defp local_watch(cursor, send_event) do
    unless is_binary(cursor) and Regex.match?(~r/^\d+-0$/, cursor), do: raise(GRPC.RPCError, status: :invalid_argument, message: "invalid_cursor")
    Registry.register(MirrorNeuron.Runtime.EventRegistry, :interactions, [])
    try do
      follow(cursor, send_event)
    after
      Registry.unregister(MirrorNeuron.Runtime.EventRegistry, :interactions)
    end
  end
  defp follow(cursor, send_event) do
    case InteractionStore.events(cursor) do
      {:ok, events} ->
        Enum.each(events, send_event)
        latest = case List.last(events) do nil -> cursor; event -> event["id"] end
        if length(events) == 200 do
          follow(latest, send_event)
        else
          receive do
            :interaction_changed -> follow(latest, send_event)
          after
            15_000 -> send_event.(%{"type" => "heartbeat"}); follow(latest, send_event)
          end
        end
      {:error, error} -> send_event.(%{"error" => error})
    end
  end
  defp peers do
    nodes = Enum.map(FederationRegistry.public_list(), & &1["node_name"])
    if length(nodes) > 32, do: raise(GRPC.RPCError, status: :resource_exhausted, message: "interaction_peer_limit")
    nodes
  end
  defp local_node, do: to_string(NodeAdapter.self())
  defp remote(node, input, allow_missing \\ false) do
    response = FederationClient.interaction_command(node, request(input))
    value = Jason.decode!(response.resource_json)
    if value["error"] && not (allow_missing && value["error"] == "not_found"),
      do: raise(GRPC.RPCError, status: :failed_precondition, message: value["error"])
    value
  end
  defp request(input), do: %SetResourceRequest{resource_json: Jason.encode!(input), version: 1}
  defp encode_cursor(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
  defp decode_cursor!(value) when is_binary(value) and byte_size(value) <= 8192 do
    with {:ok, json} <- Base.url_decode64(value, padding: false), {:ok, cursors} when is_map(cursors) <- Jason.decode(json) do
      cursors
    else
      _ -> raise GRPC.RPCError, status: :invalid_argument, message: "invalid_cursor"
    end
  end
  defp decode_cursor!(_), do: raise(GRPC.RPCError, status: :invalid_argument, message: "invalid_cursor")
  defp authorize!(stream) do
    Auth.authorize_identity!(stream)
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("Interactions")
  end
  defp decode!(json) when byte_size(json) <= 65_536 do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> raise GRPC.RPCError, status: :invalid_argument, message: "invalid_interaction_command"
    end
  end
  defp decode!(_), do: raise(GRPC.RPCError, status: :invalid_argument, message: "payload_too_large")
  defp reply({:ok, value}), do: %GetResourceResponse{resource_json: Jason.encode!(value), version: 1}
  defp reply({:error, code}), do: %GetResourceResponse{resource_json: Jason.encode!(%{"error" => code}), version: 1}
end
