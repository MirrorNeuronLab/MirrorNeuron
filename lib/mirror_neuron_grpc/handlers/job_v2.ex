defmodule MirrorNeuron.Grpc.Handlers.JobV2 do
  @moduledoc false

  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.Grpc.JobV2Projection
  alias Mirrorneuron.Job.V2.JsonResponse

  @interface_version 2

  def create_job(request, _stream) do
    request
    |> with_json_bundle(fn tmp_dir ->
      MirrorNeuron.create_job(tmp_dir,
        job_id: Support.blank_to_nil(request.job_id),
        resolved_configuration: Support.decode_json_map(request.resolved_configuration_json),
        storage: Support.decode_json_map(request.storage_json)
      )
    end)
    |> respond_definition(:summary)
  end

  def get_job(request, _stream) do
    request.job_id
    |> MirrorNeuron.get_job()
    |> respond_definition(:detail)
  end

  def list_jobs(request, _stream) do
    case MirrorNeuron.list_stable_jobs(include_archived: request.include_archived) do
      {:ok, jobs} -> response(%{"data" => JobV2Projection.summaries(jobs)})
      error -> respond(error)
    end
  end

  def update_job(request, _stream) do
    request.job_id
    |> MirrorNeuron.update_job(Support.decode_json_map(request.attrs_json))
    |> respond_definition(:summary)
  end

  def archive_job(request, _stream) do
    request.job_id
    |> MirrorNeuron.archive_job()
    |> respond_definition(:summary)
  end

  def reset_job_data(request, _stream) do
    request.job_id
    |> MirrorNeuron.reset_job_data()
    |> respond_definition(:summary)
  end

  def delete_job(request, _stream) do
    case MirrorNeuron.delete_stable_job(request.job_id, confirmed: request.confirmed) do
      :ok -> response(%{"job_id" => request.job_id, "status" => "deleted"})
      error -> respond(error)
    end
  end

  def start_run(request, _stream) do
    opts =
      []
      |> Support.maybe_put_opt(:run_id, Support.blank_to_nil(request.run_id))
      |> Keyword.put(:inputs, Support.decode_json_map(request.inputs_json))

    case MirrorNeuron.start_run(request.job_id, opts) do
      {:ok, run_id, _pid} ->
        response(%{
          "job_id" => request.job_id,
          "run_id" => run_id,
          "status" => "pending"
        })

      error ->
        respond(error)
    end
  end

  def list_runs(request, _stream) do
    case MirrorNeuron.list_runs(request.job_id) do
      {:ok, runs} ->
        response(%{"job_id" => request.job_id, "data" => JobV2Projection.runs(runs)})

      error ->
        respond(error)
    end
  end

  def get_run(request, _stream) do
    case MirrorNeuron.inspect_job(request.run_id) do
      {:ok, run} -> response(JobV2Projection.run(run, request.run_id))
      error -> respond(error)
    end
  end

  def pause_run(request, _stream), do: control_run(request.run_id, &MirrorNeuron.pause/1)
  def resume_run(request, _stream), do: control_run(request.run_id, &MirrorNeuron.resume/1)
  def cancel_run(request, _stream), do: control_run(request.run_id, &MirrorNeuron.cancel/1)

  def delete_run(request, _stream) do
    case MirrorNeuron.delete_run(request.run_id, confirmed: request.confirmed) do
      :ok -> response(%{"run_id" => request.run_id, "status" => "deleted"})
      error -> respond(error)
    end
  end

  def create_job_schedule(request, _stream) do
    schedule = Support.decode_json_map(request.schedule_json)
    source = Support.decode_json_map(request.source_json)

    case MirrorNeuron.create_job_schedule(request.job_id, schedule, source: source) do
      {:ok, created} -> response(JobV2Projection.schedule(created))
      error -> respond(error)
    end
  end

  defp control_run(run_id, operation) do
    case operation.(run_id) do
      {:ok, status} -> response(%{"run_id" => run_id, "status" => status})
      :ok -> response(%{"run_id" => run_id, "status" => "accepted"})
      error -> respond(error)
    end
  end

  defp with_json_bundle(request, callback) do
    Support.with_request_bundle(request.manifest_json, request.payloads, fn tmp_dir ->
      callback.(tmp_dir)
    end)
  end

  defp respond_definition({:ok, definition}, :summary),
    do: response(JobV2Projection.summary(definition))

  defp respond_definition({:ok, definition}, :detail),
    do: response(JobV2Projection.detail(definition))

  defp respond_definition(error, _projection), do: respond(error)

  defp respond({:ok, value}), do: response(value)

  defp respond({:error, reason}) do
    Support.raise_runtime_error!(reason)
  end

  defp respond(other), do: response(other)

  defp response(value) do
    %JsonResponse{
      result_json: Jason.encode!(versioned(value)),
      version: @interface_version
    }
  end

  defp versioned(value) when is_map(value), do: Map.put_new(value, "version", @interface_version)
  defp versioned(value), do: %{"version" => @interface_version, "result" => value}
end
