defmodule MirrorNeuron.Grpc.Handlers.Job.Responses do
  @moduledoc "Routes bounded response queries and reads durable response turns."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.Grpc.Validation

  def query_job_response(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil -> query_local_job_response(request)
      owner -> Remote.forward_call(owner, :query_job_response, request, stream)
    end
  end

  def get_job_response_turn(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil -> get_local_job_response_turn(request)
      owner -> Remote.forward_call(owner, :get_job_response_turn, request, stream)
    end
  end

  defp get_local_job_response_turn(request) do
    case MirrorNeuron.get_job_response_turn(request.job_id, request.turn_id) do
      {:ok, turn} -> Encoding.response(turn)
      {:error, reason} -> Encoding.respond({:error, reason})
    end
  end

  defp query_local_job_response(request) do
    with {:ok, context} <- Validation.decode_json_map(request.context_json),
         {:ok, answer} <-
           MirrorNeuron.query_job_response(request.job_id, %{
             "question" => request.question,
             "conversation_id" => Support.blank_to_nil(request.conversation_id),
             "request_id" => Support.blank_to_nil(request.request_id),
             "context" => context
           }) do
      Encoding.response(answer)
    else
      {:error, reason} -> Encoding.respond({:error, reason})
    end
  end
end
