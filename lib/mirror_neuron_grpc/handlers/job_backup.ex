defmodule MirrorNeuron.Grpc.Handlers.JobBackup do
  @moduledoc false
  alias MirrorNeuron.Grpc.Handlers.Support

  def export_job_backup(request, stream) do
    case MirrorNeuron.Cluster.FederatedJobRouting.job_owner(request.job_id) do
      nil ->
        case MirrorNeuron.Backup.DurableJob.export(
               request.job_id,
               &GRPC.Server.send_reply(stream, &1)
             ) do
          :ok -> stream
          {:error, reason} -> Support.raise_runtime_error!(reason)
        end

      owner ->
        hops = Map.get(GRPC.Stream.get_headers(stream), "x-mn-federation-hop", "0")

        if hops != "0",
          do:
            raise(GRPC.RPCError,
              status: GRPC.Status.failed_precondition(),
              message: "backup owner unavailable"
            )

        MirrorNeuron.Cluster.FederationClient.stream_job_backup(
          owner,
          request,
          &GRPC.Server.send_reply(stream, &1)
        )

        stream
    end
  rescue
    error in ArgumentError ->
      raise GRPC.RPCError,
        status: GRPC.Status.failed_precondition(),
        message: Exception.message(error)
  end

  def restore_job_backup(%{chunks: chunks}, _stream) do
    case MirrorNeuron.Backup.DurableJob.restore(chunks) do
      {:ok, definition} ->
        %Mirrorneuron.Job.V1.JsonResponse{
          result_json: Support.versioned_json(definition),
          version: 1
        }

      {:error, reason} ->
        Support.raise_runtime_error!(reason)
    end
  rescue
    error in [ArgumentError, Jason.DecodeError] ->
      raise GRPC.RPCError,
        status: GRPC.Status.invalid_argument(),
        message: Exception.message(error)
  end
end
