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
          summary_json:
            Support.versioned_json(
              Map.put(overview, "identity", MirrorNeuron.Cluster.RuntimeIdentity.health())
            ),
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
      resource_json:
        Support.versioned_json(
          Map.put(
            MirrorNeuron.resource_list(),
            "retry_checkpoint_storage",
            MirrorNeuron.Persistence.RedisStore.retained_checkpoint_storage()
          )
        ),
      version: @interface_version
    }
  end

  def set_resource(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SetResource")

    with {:ok, attrs} <- Jason.decode(request.resource_json),
         :ok <- authorize_admission(attrs, stream),
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

  defp authorize_admission(%{"operation" => "node_admission"}, stream) do
    MirrorNeuron.Grpc.Auth.authorize_identity!(stream)
    :ok
  end

  defp authorize_admission(%{"operation" => "workflow_budget"}, stream) do
    MirrorNeuron.Grpc.Auth.authorize_identity!(stream)
    :ok
  end

  defp authorize_admission(_attrs, _stream), do: :ok
end
