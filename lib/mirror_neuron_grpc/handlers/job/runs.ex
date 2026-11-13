defmodule MirrorNeuron.Grpc.Handlers.Job.Runs do
  @moduledoc "Starts, reads and controls Runs under their owning definition and retry gate."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Persistence.RedisStore
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

  def pause_run(request, stream),
    do: route_run_control(request, :pause_run, &MirrorNeuron.pause/1, stream)

  def resume_run(request, stream),
    do: route_run_control(request, :resume_run, &resume_paused_run/1, stream)

  defp resume_paused_run(run_id) do
    case RedisStore.fetch_job(run_id) do
      {:ok, %{"status" => "failed"}} ->
        {:error,
         {:run_retry_blocked,
          "This run failed. Use mn run retry #{run_id} --dry-run to check recovery."}}

      {:ok, %{"stable_job_id" => job_id}} when is_binary(job_id) ->
        MirrorNeuron.Runtime.StableJob.with_start_gate(job_id, fn ->
          MirrorNeuron.resume(run_id)
        end)

      _ ->
        MirrorNeuron.resume(run_id)
    end
  end

  def cancel_run(request, stream) do
    cancel =
      if request.queued_only do
        fn id ->
          case MirrorNeuron.Runtime.NodeAdmission.cancel(id) do
            :ok -> {:ok, "cancelled"}
            error -> error
          end
        end
      else
        &MirrorNeuron.cancel/1
      end

    route_run_control(request, :cancel_run, cancel, stream)
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

  defp control_run(run_id, operation) do
    case operation.(run_id) do
      {:ok, status} -> Encoding.response(%{"run_id" => run_id, "status" => status})
      :ok -> Encoding.response(%{"run_id" => run_id, "status" => "accepted"})
      error -> Encoding.respond(error)
    end
  end

  defp route_run_control(request, function, operation, stream) do
    case Remote.remote_run_owner(request.run_id) do
      nil -> control_run(request.run_id, operation)
      owner -> Remote.forward_call(owner, function, request, stream)
    end
  end
end
