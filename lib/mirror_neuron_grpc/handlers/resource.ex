defmodule MirrorNeuron.Grpc.Handlers.Resource do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Grpc.Handlers.Support

  alias Mirrorneuron.Cluster.V1.{
    GetResourceResponse,
    GetSystemSummaryResponse,
    SetResourceResponse
  }

  def get_system_summary(_request, _stream) do
    case MirrorNeuron.Monitor.cluster_overview() do
      {:ok, overview} ->
        %GetSystemSummaryResponse{
          summary_json: Support.versioned_json(overview),
          version: @interface_version
        }

      _ ->
        %GetSystemSummaryResponse{
          summary_json: Support.versioned_json(%{}),
          version: @interface_version
        }
    end
  end

  def get_resource(_request, _stream) do
    %GetResourceResponse{
      resource_json: Support.versioned_json(MirrorNeuron.resource_list()),
      version: @interface_version
    }
  end

  def set_resource(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SetResource")

    with {:ok, attrs} <- Jason.decode(request.resource_json),
         {:ok, resource} <- MirrorNeuron.resource_set(attrs) do
      %SetResourceResponse{
        resource_json: Support.versioned_json(resource),
        version: @interface_version
      }
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "resource body must be valid JSON: #{Exception.message(error)}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: to_string(reason)
    end
  end
end
