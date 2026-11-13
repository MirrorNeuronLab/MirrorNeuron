defmodule MirrorNeuron.Grpc.Handlers.Job.Runs do
  @moduledoc "Starts, reads and controls Runs under their owning definition and retry gate."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Handlers.RunAdmission
  alias MirrorNeuron.Grpc.Handlers.Support

  def start_run(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil ->
        start_local_run(request)

      owner ->
        RunAdmission.ensure_peer_admission!(owner)
        Remote.forward_call(owner, :start_run, request, stream)
    end
  end

  defp start_local_run(request) do
    opts =
      []
      |> Support.maybe_put_opt(:run_id, Support.blank_to_nil(request.run_id))
      |> Keyword.put(:inputs, Support.decode_json_map(request.inputs_json))
      |> Keyword.put(:replace_existing_run, request.replace_existing_run)
      |> Keyword.put(
        :admission_policy,
        if(request.admission_policy == "", do: "start_now", else: request.admission_policy)
      )

    result =
      MirrorNeuron.Runtime.RunStartRequest.run(
        request.job_id,
        request.idempotency_key,
        {request.run_id, request.inputs_json, request.replace_existing_run,
         request.admission_policy},
        fn run_id, identity ->
          MirrorNeuron.start_run_result(
            request.job_id,
            opts |> Keyword.put(:run_id, run_id) |> Keyword.put(:start_request_identity, identity)
          )
        end
      )

    case result do
      {:ok, started} ->
        started
        |> Map.drop([:pid, "pid"])
        |> Encoding.response()

      error ->
        Encoding.respond(error)
    end
  end

  def list_runs(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil -> list_local_runs(request)
      owner -> Remote.remote_runs_read(owner, request, stream)
    end
  end

  defp list_local_runs(request) do
    case MirrorNeuron.list_runs_page(request.job_id,
           page_size: Encoding.page_size(request.page_size),
           page_token: Support.blank_to_nil(request.page_token)
         ) do
      {:ok, runs, next_page_token} ->
        Encoding.response(%{
          "job_id" => request.job_id,
          "items" => JobProjection.runs(runs),
          "next_page_token" => next_page_token
        })

      error ->
        Encoding.respond(error)
    end
  end

  def get_run(request, stream) do
    case MirrorNeuron.inspect_job(request.run_id) do
      {:ok, run} ->
        Encoding.response(JobProjection.run_detail(run, request.run_id))

      _error ->
        if MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 do
          Encoding.respond({:error, :not_found})
        else
          Remote.remote_read(
            request.run_id,
            &Remote.remote_run_owner/1,
            :get_run,
            request,
            stream
          )
        end
    end
  end

  def pause_run(request, stream), do: route_run_control(request, :pause_run, "pause", stream)
  def resume_run(request, stream), do: route_run_control(request, :resume_run, "resume", stream)
  def cancel_run(request, stream), do: route_run_control(request, :cancel_run, "cancel", stream)

  def get_run_control(request, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil ->
        Encoding.respond(MirrorNeuron.Runtime.RunControl.get(request.run_id, request.request_id))

      owner ->
        Remote.forward_call(owner, :get_run_control, request, stream)
    end
  end

  def delete_run(request, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil ->
        case MirrorNeuron.delete_run(request.run_id, confirmed: request.confirmed) do
          :ok -> Encoding.response(%{"run_id" => request.run_id, "status" => "deleted"})
          error -> Encoding.respond(error)
        end

      owner ->
        Remote.forward_call(owner, :delete_run, request, stream)
    end
  end

  defp route_run_control(request, function, action, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil ->
        Encoding.respond(
          MirrorNeuron.Runtime.RunControl.submit(
            request.run_id,
            action,
            request.request_id,
            request.queued_only
          )
        )

      owner ->
        Remote.forward_call(owner, function, request, stream)
    end
  end
end
