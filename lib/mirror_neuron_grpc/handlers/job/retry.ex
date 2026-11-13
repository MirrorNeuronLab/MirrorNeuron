defmodule MirrorNeuron.Grpc.Handlers.Job.Retry do
  @moduledoc "Validates retry configuration and routes checkpoint planning and submission."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Validation

  def plan_run_retry(request, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil ->
        with {:ok, overrides} <- Validation.decode_json_map(request.configuration_overrides_json) do
          Encoding.respond(MirrorNeuron.Runtime.RunRetry.plan(request.run_id, overrides))
        else
          error -> Encoding.respond(error)
        end

      owner ->
        Remote.forward_call(owner, :plan_run_retry, request, stream)
    end
  end

  def retry_run(request, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil ->
        with {:ok, overrides} <- Validation.decode_json_map(request.configuration_overrides_json) do
          Encoding.respond(
            MirrorNeuron.Runtime.RunRetry.submit(request.run_id, %{
              "configuration_overrides" => overrides,
              "expected_attempt" => request.expected_attempt,
              "checkpoint_revision" => request.checkpoint_revision,
              "idempotency_key" => request.idempotency_key,
              "admission_policy" =>
                if(request.admission_policy == "",
                  do: "start_now",
                  else: request.admission_policy
                )
            })
          )
        else
          error -> Encoding.respond(error)
        end

      owner ->
        Remote.forward_call(owner, :retry_run, request, stream)
    end
  end
end
