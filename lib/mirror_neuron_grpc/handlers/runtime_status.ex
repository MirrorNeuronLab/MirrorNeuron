defmodule MirrorNeuron.Grpc.Handlers.RuntimeStatus do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.Cluster.NodeAdapter

  alias Mirrorneuron.Cluster.V1.{GetResourceResponse, SetResourceResponse}

  def get_runtime_statuses(_request, _stream) do
    local_node = to_string(NodeAdapter.self())

    nodes =
      NodeState.list()
      |> Enum.filter(&runtime_node_status?/1)
      |> Enum.map(&runtime_node_status/1)
      |> Enum.sort_by(& &1["name"])

    with {:ok, all_events} <- NodeState.runtime_status_events(),
         auto_ack_event_ids <- auto_ack_event_ids(all_events, local_node),
         {:ok, _auto_acked_count} <-
           NodeState.ack_runtime_status_events(auto_ack_event_ids),
         events <- remote_model_events(all_events, local_node),
         {:ok, all_cluster_events} <- NodeState.cluster_runtime_status_events(),
         {:ok, cluster_status} <- NodeState.cluster_runtime_status(),
         event_ids <- Enum.map(all_cluster_events, & &1["id"]),
         {:ok, acked_count} <- NodeState.ack_cluster_runtime_status_events(event_ids) do
      %GetResourceResponse{
        resource_json:
          Support.versioned_json(%{
            "nodes" => nodes,
            "events" => events,
            "cluster_status" => cluster_status,
            "cluster_events" => remote_events(all_cluster_events, local_node),
            "cluster_event_ack" => %{
              "status" => "acked",
              "event_ids" => event_ids,
              "acked_count" => acked_count
            }
          }),
        version: @interface_version
      }
    else
      {:error, reason} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "could not synchronize runtime status: #{inspect(reason)}"
    end
  end

  def publish_runtime_status(request, _stream) do
    with {:ok, attrs} when is_map(attrs) <- Jason.decode(request.resource_json),
         {:ok, result} <-
           NodeState.publish_runtime_status(
             Map.get(attrs, "domain"),
             Map.get(attrs, "revision"),
             Map.get(attrs, "status")
           ) do
      %SetResourceResponse{
        resource_json: Support.versioned_json(result),
        version: @interface_version
      }
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "runtime status body must be valid JSON: #{Exception.message(error)}"

      {:ok, _other} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "runtime status body must be a JSON object"

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: to_string(reason)
    end
  end

  def ack_runtime_status_events(request, _stream) do
    with {:ok, attrs} when is_map(attrs) <- Jason.decode(request.resource_json),
         event_ids when is_list(event_ids) <- Map.get(attrs, "event_ids"),
         normalized =
           event_ids |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
         {:ok, count} <- NodeState.ack_runtime_status_events(normalized) do
      %SetResourceResponse{
        resource_json:
          Support.versioned_json(%{
            "status" => "acked",
            "event_ids" => normalized,
            "acked_count" => count
          }),
        version: @interface_version
      }
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message:
            "runtime status acknowledgement must be valid JSON: #{Exception.message(error)}"

      nil ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "runtime status acknowledgement requires event_ids"

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "could not acknowledge runtime status events: #{inspect(reason)}"

      _invalid ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "runtime status acknowledgement event_ids must be a list"
    end
  end

  defp runtime_node_status?(state) when is_map(state) do
    Map.get(state, "operator_disconnect") != true and
      Map.get(state, "status", "healthy") not in ["disconnected", "offline", "quarantined"]
  end

  defp runtime_node_status?(_state), do: false

  defp runtime_node_status(state) do
    node_name = to_string(Map.get(state, "node") || "")
    host = Map.get(state, "grpc_host") || Map.get(state, "address") || node_host(node_name)

    %{
      "name" => node_name,
      "grpc_host" => host,
      "status" => Map.get(state, "status", "healthy"),
      "self" => node_name == to_string(NodeAdapter.self()),
      "runtime_status" => Map.get(state, "runtime_status", %{})
    }
  end

  defp auto_ack_event_ids(events, local_node) do
    events
    |> Enum.filter(fn event ->
      to_string(event["node"] || "") == local_node or event["domain"] != "models"
    end)
    |> Enum.map(& &1["id"])
  end

  defp remote_model_events(events, local_node) do
    events
    |> remote_events(local_node)
    |> Enum.filter(&(&1["domain"] == "models"))
  end

  defp remote_events(events, local_node) do
    Enum.reject(events, &(to_string(&1["node"] || "") == local_node))
  end

  defp node_host(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [_name, host] -> host
      _ -> nil
    end
  end
end
