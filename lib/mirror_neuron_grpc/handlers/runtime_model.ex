defmodule MirrorNeuron.Grpc.Handlers.RuntimeModel do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.ModelServices
  alias Mirrorneuron.Cluster.V1.SetResourceResponse

  def sync_lite_llm_gateway(request, _stream) do
    dispatch_json_resource(request, "LiteLLM gateway sync", fn attrs ->
      node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
      ModelServices.sync_litellm_gateway_on_node(node_name, attrs)
    end)
  end

  def remove_lite_llm_gateway_route(request, _stream) do
    dispatch_json_resource(request, "LiteLLM gateway route removal", fn attrs ->
      node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
      ModelServices.remove_litellm_gateway_route_on_node(node_name, attrs)
    end)
  end

  def prepare_runtime_model(request, _stream) do
    dispatch_json_resource(request, "runtime model prepare", fn attrs ->
      node_name = Map.get(attrs, "node") || Map.get(attrs, :node)
      ModelServices.prepare_runtime_model_on_node(node_name, attrs)
    end)
  end

  defp dispatch_json_resource(request, label, fun) do
    with {:ok, attrs} when is_map(attrs) <- Jason.decode(request.resource_json),
         {:ok, result} <- fun.(attrs) do
      %SetResourceResponse{
        resource_json: Support.versioned_json(result),
        version: @interface_version
      }
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
end
