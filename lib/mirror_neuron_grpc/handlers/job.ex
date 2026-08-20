defmodule MirrorNeuron.Grpc.Handlers.Job do
  @moduledoc false

  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Grpc.Validation
  alias MirrorNeuron.Runtime.LiveInput
  alias MirrorNeuron.Runtime.Idempotency
  alias Mirrorneuron.Job.V1.JsonResponse

  @interface_version 1

  def create_job(request, _stream) do
    Idempotency.run(
      "create-job",
      request.idempotency_key,
      {request.manifest_json, request.payloads, request.job_id,
       request.resolved_configuration_json, request.storage_json},
      fn ->
        request
        |> with_json_bundle(fn tmp_dir ->
          MirrorNeuron.create_job(tmp_dir,
            job_id: Support.blank_to_nil(request.job_id),
            resolved_configuration: Support.decode_json_map(request.resolved_configuration_json),
            storage: Support.decode_json_map(request.storage_json)
          )
        end)
      end
    )
    |> respond_definition(:summary)
  end

  def get_job(request, _stream) do
    request.job_id
    |> MirrorNeuron.get_job()
    |> respond_definition(:detail)
  end

  def list_jobs(request, _stream) do
    case MirrorNeuron.list_stable_jobs_page(
           include_archived: request.include_archived,
           page_size: page_size(request.page_size),
           page_token: Support.blank_to_nil(request.page_token)
         ) do
      {:ok, jobs, next_page_token} ->
        response(%{
          "items" => JobProjection.summaries(jobs),
          "next_page_token" => next_page_token
        })

      error ->
        respond(error)
    end
  end

  def update_job(request, _stream) do
    attrs = Support.decode_json_map(request.attrs_json)

    result =
      if String.trim(request.manifest_json || "") == "" do
        MirrorNeuron.update_job(request.job_id, attrs,
          expected_revision: request.expected_revision
        )
      else
        request
        |> with_json_bundle(fn tmp_dir ->
          MirrorNeuron.update_job_bundle(request.job_id, tmp_dir, attrs,
            expected_revision: request.expected_revision
          )
        end)
      end

    respond_definition(result, :summary)
  end

  def archive_job(request, _stream) do
    request.job_id
    |> MirrorNeuron.archive_job(expected_revision: request.expected_revision)
    |> respond_definition(:summary)
  end

  def reset_job_data(request, _stream) do
    request.job_id
    |> MirrorNeuron.reset_job_data()
    |> respond_definition(:summary)
  end

  def delete_job(request, _stream) do
    case MirrorNeuron.delete_stable_job(request.job_id,
           confirmed: request.confirmed,
           expected_revision: request.expected_revision
         ) do
      {:ok, retired_resources} ->
        response(%{
          "job_id" => request.job_id,
          "status" => "deleted",
          "retired_definition_resources" => retired_resources
        })

      error ->
        respond(error)
    end
  end

  def start_run(request, _stream) do
    opts =
      []
      |> Support.maybe_put_opt(:run_id, Support.blank_to_nil(request.run_id))
      |> Keyword.put(:inputs, Support.decode_json_map(request.inputs_json))

    result =
      Idempotency.run(
        "start-run:#{request.job_id}",
        request.idempotency_key,
        {request.run_id, request.inputs_json},
        fn ->
          MirrorNeuron.start_run(request.job_id, opts)
        end
      )

    case result do
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
    case MirrorNeuron.list_runs_page(request.job_id,
           page_size: page_size(request.page_size),
           page_token: Support.blank_to_nil(request.page_token)
         ) do
      {:ok, runs, next_page_token} ->
        response(%{
          "job_id" => request.job_id,
          "items" => JobProjection.runs(runs),
          "next_page_token" => next_page_token
        })

      error ->
        respond(error)
    end
  end

  def get_run(request, _stream) do
    case MirrorNeuron.inspect_job(request.run_id) do
      {:ok, run} -> response(JobProjection.run(run, request.run_id))
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

  def send_run_input(request, _stream) do
    with :ok <- validate_live_input_size(request.payload_json),
         {:ok, payload} <- Validation.decode_json_map(request.payload_json),
         {:ok, accepted} <-
           LiveInput.send(
             request.run_id,
             request.input_id,
             payload,
             request.idempotency_key
           ) do
      response(accepted)
    else
      {:error, reason} when is_binary(reason) ->
        respond({:error, {:invalid_live_input, reason}})

      error ->
        respond(error)
    end
  end

  def create_job_schedule(request, _stream) do
    schedule = Support.decode_json_map(request.schedule_json)
    source = Support.decode_json_map(request.source_json)

    result =
      Idempotency.run(
        "create-job-schedule:#{request.job_id}",
        request.idempotency_key,
        {request.schedule_json, request.source_json},
        fn -> MirrorNeuron.create_job_schedule(request.job_id, schedule, source: source) end
      )

    case result do
      {:ok, created} -> response(JobProjection.schedule(created))
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
    do: response(JobProjection.summary(definition))

  defp respond_definition({:ok, definition}, :detail),
    do: response(JobProjection.detail(definition))

  defp respond_definition(error, _projection), do: respond(error)

  defp respond({:ok, value}), do: response(value)

  defp respond({:error, reason}) do
    Support.raise_runtime_error!(reason)
  end

  defp respond(other), do: response(other)

  defp validate_live_input_size(payload_json) when is_binary(payload_json) do
    if byte_size(payload_json) <= LiveInput.max_payload_bytes(),
      do: :ok,
      else: {:error, {:invalid_live_input, "payload exceeds the live-input size limit"}}
  end

  defp validate_live_input_size(_payload_json),
    do: {:error, {:invalid_live_input, "payload must be valid JSON"}}

  defp response(value) do
    %JsonResponse{
      result_json: Jason.encode!(value),
      version: @interface_version,
      revision: revision(value),
      next_page_token: if(is_map(value), do: value["next_page_token"] || "", else: "")
    }
  end

  defp revision(%{"revision" => revision}) when is_integer(revision), do: revision
  defp revision(_value), do: 0

  defp page_size(0), do: 50
  defp page_size(value), do: value
end

