defmodule MirrorNeuron.Grpc.Handlers.RuntimeModel do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, NodeAdapter}
  alias MirrorNeuron.Grpc.Auth
  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.ModelServices
  alias Mirrorneuron.Cluster.V1.SetResourceResponse

  def sync_lite_llm_gateway(request, stream) do
    dispatch_json_resource(
      request,
      "LiteLLM gateway sync",
      :sync_lite_llm_gateway,
      stream,
      fn attrs ->
        node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
        ModelServices.sync_litellm_gateway_on_node(node_name, attrs)
      end
    )
  end

  def remove_lite_llm_gateway_route(request, stream) do
    dispatch_json_resource(
      request,
      "LiteLLM gateway route removal",
      :remove_lite_llm_gateway_route,
      stream,
      fn attrs ->
        node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
        ModelServices.remove_litellm_gateway_route_on_node(node_name, attrs)
      end
    )
  end

  def prepare_runtime_model(request, stream) do
    dispatch_json_resource(
      request,
      "runtime model prepare",
      :prepare_runtime_model,
      stream,
      fn attrs ->
        node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
        ModelServices.prepare_runtime_model_on_node(node_name, attrs)
      end
    )
  end

  defp dispatch_json_resource(request, label, command, stream, fun) do
    with {:ok, attrs} when is_map(attrs) <- Jason.decode(request.resource_json),
         {:ok, response} <- route_resource_command(attrs, command, request, stream, fun) do
      response
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "#{label} body must be valid JSON: #{Exception.message(error)}"

      {:ok, _other} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "#{label} body must be a JSON object"

      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, reason} ->
        raise GRPC.RPCError, status: :failed_precondition, message: to_string(reason)
    end
  end

  defp route_resource_command(attrs, command, request, stream, local_fun) do
    case remote_owner(attrs) do
      nil ->
        with {:ok, result} <- local_fun.(attrs) do
          {:ok,
           %SetResourceResponse{
             resource_json: Support.versioned_json(result),
             version: @interface_version
           }}
        end

      owner ->
        if Auth.federation_hop(stream) > 0 do
          raise GRPC.RPCError,
            status: GRPC.Status.failed_precondition(),
            message: "MN_FEDERATION_LOOP: forwarded request cannot be forwarded again"
        else
          {:ok, FederationClient.call_cluster(owner, command, request)}
        end
    end
  end

  defp remote_owner(attrs) do
    node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
    node_name = if is_binary(node_name), do: String.trim(node_name), else: ""

    if node_name != "" and node_name != to_string(NodeAdapter.self()) and
         match?({:ok, _peer}, FederationRegistry.fetch(node_name)) do
      node_name
    end
  end
end
