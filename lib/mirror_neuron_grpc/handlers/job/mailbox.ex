defmodule MirrorNeuron.Grpc.Handlers.Job.Mailbox do
  @moduledoc false
  alias MirrorNeuron.Grpc.Handlers.Job.{Encoding, Remote}
  alias MirrorNeuron.Grpc.Validation

  def job_mailbox(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil ->
        with true <- byte_size(request.arguments_json) <= 8192,
             {:ok, args} <- Validation.decode_json_map(request.arguments_json) do
          MirrorNeuron.Runtime.JobMailbox.call(request.job_id, request.tool, args)
        else
          _ -> {:error, :invalid_mailbox_request}
        end
        |> Encoding.respond()

      owner ->
        Remote.forward_call(owner, :job_mailbox, request, stream)
    end
  end
end
