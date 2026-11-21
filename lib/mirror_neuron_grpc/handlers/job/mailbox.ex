defmodule MirrorNeuron.Grpc.Handlers.Job.Mailbox do
  @moduledoc false
  alias MirrorNeuron.Cluster.FederationClient
  alias MirrorNeuron.Grpc.{Auth, Validation}
  alias MirrorNeuron.Grpc.Handlers.Job.{Encoding, Remote}
  alias MirrorNeuron.JobData
  alias MirrorNeuron.Runtime.JobMailbox
  alias Mirrorneuron.Job.V1.JobRequest

  @prepare "prepare_mailbox_message"
  @chunk "read_mailbox_owner_chunk"

  def job_mailbox(request, stream) do
    with :ok <- JobData.validate_id(request.job_id),
         true <- byte_size(request.arguments_json) <= 8192,
         {:ok, args} <- Validation.decode_json_map(request.arguments_json),
         {:ok, inbox} <- inbox_owner_job(request, args) do
      dispatch(request, args, inbox, stream)
    else
      _ -> Encoding.respond({:error, :invalid_mailbox_request})
    end
  end

  defp inbox_owner_job(%{tool: "send_mailbox_message"}, %{"recipient_job_id" => id}) do
    with :ok <- JobData.validate_id(id), do: {:ok, id}
  end

  defp inbox_owner_job(%{job_id: job, tool: tool}, _)
       when tool in [
              @prepare,
              @chunk,
              "read_mailbox_attachment",
              "list_mailbox_messages",
              "acknowledge_mailbox_message"
            ],
       do: {:ok, job}

  defp inbox_owner_job(_, _), do: :error

  # Only the recipient's Core requests an envelope. This operation cannot write an inbox.
  defp dispatch(%{tool: @prepare, job_id: job}, args, _inbox, stream) do
    Auth.authorize_federation_peer!(stream)

    if JobData.validate_id(args["recipient_job_id"]) == :ok do
      JobMailbox.prepare_for_peer(job, args, &lookup_peer/1) |> Encoding.respond()
    else
      Encoding.respond({:error, :invalid_mailbox_request})
    end
  end

  defp dispatch(%{tool: @chunk, job_id: job}, args, _inbox, stream) do
    Auth.authorize_federation_peer!(stream)
    JobMailbox.Attachment.read_chunk(job, args["ref"], args["offset"]) |> Encoding.respond()
  end

  defp dispatch(request, args, inbox, stream) do
    case Remote.remote_job_owner(inbox) do
      nil -> local_call(request, args, inbox) |> Encoding.respond()
      owner -> Remote.forward_call(owner, :job_mailbox, request, stream)
    end
  end

  defp local_call(%{tool: "send_mailbox_message", job_id: sender} = request, args, inbox) do
    case Remote.remote_job_owner(sender) do
      nil ->
        JobMailbox.call(sender, request.tool, args, &lookup_peer/1)

      owner ->
        response = FederationClient.call(owner, :job_mailbox, %{request | tool: @prepare})

        with {:ok, %{"sender_job_id" => ^sender, "recipient_job_id" => ^inbox} = message} <-
               Validation.decode_json_map(response.result_json) do
          JobMailbox.deliver_from_peer(inbox, message, &lookup_peer/1)
        else
          _ -> {:error, :invalid_mailbox_request}
        end
    end
  end

  defp local_call(%{tool: "read_mailbox_attachment"} = request, args, inbox) do
    with {:ok, {source, ref}} <- JobMailbox.attachment_source(inbox, args, &lookup_peer/1) do
      case Remote.remote_run_owner(ref["run_id"]) do
        nil ->
          JobMailbox.Attachment.read_chunk(source, ref, args["offset"])

        owner ->
          params = Jason.encode!(%{"ref" => ref, "offset" => args["offset"]})

          response =
            FederationClient.call(owner, :job_mailbox, %{
              request
              | job_id: source,
                tool: @chunk,
                arguments_json: params
            })

          Jason.decode(response.result_json)
      end
    end
  end

  defp local_call(request, args, _inbox),
    do: JobMailbox.call(request.job_id, request.tool, args, &lookup_peer/1)

  # Legacy reciprocal pairs store only the peer Job ID. Group rosters already
  # contain both identities and never need this extra lookup.
  defp lookup_peer(job) do
    case Remote.remote_job_owner(job) do
      nil ->
        MirrorNeuron.get_job(job)

      owner ->
        response = FederationClient.call(owner, :get_job, %JobRequest{job_id: job, version: 1})
        Validation.decode_json_map(response.result_json)
    end
  end
end
