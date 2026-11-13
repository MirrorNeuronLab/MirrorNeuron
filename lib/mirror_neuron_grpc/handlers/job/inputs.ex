defmodule MirrorNeuron.Grpc.Handlers.Job.Inputs do
  @moduledoc "Validates bounded live input and reads durable command acceptance receipts."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Runtime.LiveInput
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Validation

  def get_run_input_status(request, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil ->
        with :ok <-
               MirrorNeuron.Runtime.LiveInput.validate_identity(
                 request.run_id,
                 request.command_id
               ),
             {:ok, receipt} <-
               MirrorNeuron.Runtime.CommandReceipts.get(request.run_id, request.command_id) do
          Encoding.response(receipt)
        else
          error -> Encoding.respond(error)
        end

      owner ->
        Remote.forward_call(owner, :get_run_input_status, request, stream)
    end
  end

  def send_run_input(request, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil -> send_local_run_input(request)
      owner -> Remote.forward_call(owner, :send_run_input, request, stream)
    end
  end

  defp send_local_run_input(request) do
    with :ok <- validate_live_input_size(request.payload_json),
         {:ok, payload} <- Validation.decode_json_map(request.payload_json),
         {:ok, accepted} <-
           LiveInput.send(
             request.run_id,
             request.input_id,
             payload,
             request.idempotency_key
           ) do
      Encoding.response(accepted)
    else
      {:error, reason} when is_binary(reason) ->
        Encoding.respond({:error, {:invalid_live_input, reason}})

      error ->
        Encoding.respond(error)
    end
  end

  defp validate_live_input_size(payload_json) when is_binary(payload_json) do
    if byte_size(payload_json) <= LiveInput.max_payload_bytes(),
      do: :ok,
      else: {:error, {:invalid_live_input, "payload exceeds the live-input size limit"}}
  end

  defp validate_live_input_size(_payload_json),
    do: {:error, {:invalid_live_input, "payload must be valid JSON"}}
end
