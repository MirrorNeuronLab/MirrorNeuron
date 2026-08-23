defmodule MirrorNeuron.Grpc.Handlers.Job do
  @moduledoc false

  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Grpc.Validation
  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, NodeAdapter}
  alias MirrorNeuron.Runtime.LiveInput
  alias MirrorNeuron.Runtime.Idempotency
  alias Mirrorneuron.Job.V1.JsonResponse

  @interface_version 1
  @unavailable_status GRPC.Status.unavailable()

  def create_job(request, stream) do
    owner_node = Support.blank_to_nil(request.owner_node) || to_string(NodeAdapter.self())

    if owner_node != to_string(NodeAdapter.self()) do
      forward_call(owner_node, :create_job, %{request | owner_node: owner_node}, stream)
    else
      create_local_job(request, owner_node)
    end
  end

  defp create_local_job(request, owner_node) do
    Idempotency.run(
      "create-job",
      request.idempotency_key,
      {request.manifest_json, request.payloads, request.job_id,
       request.resolved_configuration_json, request.storage_json, request.owner_node},
      fn ->
        request
        |> with_json_bundle(fn tmp_dir ->
          MirrorNeuron.create_job(tmp_dir,
            job_id: Support.blank_to_nil(request.job_id),
            resolved_configuration: Support.decode_json_map(request.resolved_configuration_json),
            storage: Support.decode_json_map(request.storage_json),
            owner_node: owner_node
          )
        end)
      end
    )
    |> respond_definition(:summary)
  end

  def get_job(request, stream) do
    case MirrorNeuron.get_job(request.job_id) do
      {:ok, definition} -> response(JobProjection.detail(definition))
      _error -> remote_read(request.job_id, :get_job, request, stream)
    end
  end

  def list_jobs(request, _stream) do
    case MirrorNeuron.list_stable_jobs_page(
           include_archived: request.include_archived,
           page_size: page_size(request.page_size),
           page_token: Support.blank_to_nil(request.page_token)
         ) do
      {:ok, jobs, next_page_token} ->
        items =
          if Map.get(request, :local_only, false) do
            JobProjection.summaries(jobs)
          else
            JobProjection.summaries(jobs) ++ FederationRegistry.projections()
          end

        response(%{
          "items" => Enum.uniq_by(items, &Map.get(&1, "job_id")),
          "next_page_token" => next_page_token
        })

      error ->
        respond(error)
    end
  end

  def update_job(request, stream) do
    case remote_owner(request.job_id) do
      nil -> update_local_job(request)
      owner -> forward_call(owner, :update_job, request, stream)
    end
  end

  defp update_local_job(request) do
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
            expected_revision: request.expected_revision,
            replace_existing_run: request.replace_existing_run
          )
        end)
      end

    respond_definition(result, :summary)
  end

  def archive_job(request, stream) do
    case remote_owner(request.job_id) do
      nil ->
        request.job_id
        |> MirrorNeuron.archive_job(expected_revision: request.expected_revision)
        |> respond_definition(:summary)

      owner ->
        forward_call(owner, :archive_job, request, stream)
    end
  end

  def reset_job_data(request, stream) do
    case remote_owner(request.job_id) do
      nil -> request.job_id |> MirrorNeuron.reset_job_data() |> respond_definition(:summary)
      owner -> forward_call(owner, :reset_job_data, request, stream)
    end
  end

  def delete_job(request, stream) do
    case remote_owner(request.job_id) do
      nil -> delete_local_job(request)
      owner -> forward_call(owner, :delete_job, request, stream)
    end
  end

  defp delete_local_job(request) do
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

  def start_run(request, stream) do
    case remote_owner(request.job_id) do
      nil -> start_local_run(request)
      owner -> forward_call(owner, :start_run, request, stream)
    end
  end

  defp start_local_run(request) do
    opts =
      []
      |> Support.maybe_put_opt(:run_id, Support.blank_to_nil(request.run_id))
      |> Keyword.put(:inputs, Support.decode_json_map(request.inputs_json))
      |> Keyword.put(:replace_existing_run, request.replace_existing_run)

    result =
      Idempotency.run(
        "start-run:#{request.job_id}",
        request.idempotency_key,
        {request.run_id, request.inputs_json, request.replace_existing_run},
        fn ->
          MirrorNeuron.start_run_result(request.job_id, opts)
        end
      )

    case result do
      {:ok, started} ->
        started
        |> Map.drop([:pid, "pid"])
        |> response()

      error ->
        respond(error)
    end
  end

  def list_runs(request, stream) do
    case remote_owner(request.job_id) do
      nil -> list_local_runs(request)
      owner -> remote_runs_read(owner, request, stream)
    end
  end

  defp list_local_runs(request) do
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

  def get_run(request, stream) do
    case MirrorNeuron.inspect_job(request.run_id) do
      {:ok, run} -> response(JobProjection.run(run, request.run_id))
      _error -> remote_read(request.run_id, :get_run, request, stream)
    end
  end

  def pause_run(request, stream),
    do: route_run_control(request, :pause_run, &MirrorNeuron.pause/1, stream)

  def resume_run(request, stream),
    do: route_run_control(request, :resume_run, &MirrorNeuron.resume/1, stream)

  def cancel_run(request, stream),
    do: route_run_control(request, :cancel_run, &MirrorNeuron.cancel/1, stream)

  def delete_run(request, stream) do
    case remote_owner(request.run_id) do
      nil ->
        case MirrorNeuron.delete_run(request.run_id, confirmed: request.confirmed) do
          :ok -> response(%{"run_id" => request.run_id, "status" => "deleted"})
          error -> respond(error)
        end

      owner ->
        forward_call(owner, :delete_run, request, stream)
    end
  end

  def send_run_input(request, stream) do
    case remote_owner(request.run_id) do
      nil -> send_local_run_input(request)
      owner -> forward_call(owner, :send_run_input, request, stream)
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
      response(accepted)
    else
      {:error, reason} when is_binary(reason) ->
        respond({:error, {:invalid_live_input, reason}})

      error ->
        respond(error)
    end
  end

  def create_job_schedule(request, stream) do
    case remote_owner(request.job_id) do
      nil -> create_local_job_schedule(request)
      owner -> forward_call(owner, :create_job_schedule, request, stream)
    end
  end

  defp create_local_job_schedule(request) do
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

  def query_job_response(request, stream) do
    case remote_owner(request.job_id) do
      nil -> query_local_job_response(request)
      owner -> forward_call(owner, :query_job_response, request, stream)
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
      response(answer)
    else
      {:error, reason} -> respond({:error, reason})
    end
  end

  defp control_run(run_id, operation) do
    case operation.(run_id) do
      {:ok, status} -> response(%{"run_id" => run_id, "status" => status})
      :ok -> response(%{"run_id" => run_id, "status" => "accepted"})
      error -> respond(error)
    end
  end

  defp route_run_control(request, function, operation, stream) do
    case remote_owner(request.run_id) do
      nil -> control_run(request.run_id, operation)
      owner -> forward_call(owner, function, request, stream)
    end
  end

  defp remote_owner(resource_id) do
    FederationRegistry.projection_owner(resource_id)
  end

  defp remote_read(resource_id, function, request, stream) do
    case remote_owner(resource_id) do
      nil ->
        respond({:error, :not_found})

      owner ->
        try do
          forward_call(owner, function, request, stream)
        rescue
          error in GRPC.RPCError ->
            if error.status == @unavailable_status do
              case FederationRegistry.projection(resource_id) do
                nil ->
                  reraise error, __STACKTRACE__

                projection ->
                  response(projection)
              end
            else
              reraise error, __STACKTRACE__
            end
        end
    end
  end

  defp remote_runs_read(owner, request, stream) do
    try do
      forward_call(owner, :list_runs, request, stream)
    rescue
      error in GRPC.RPCError ->
        if error.status == @unavailable_status do
          items =
            FederationRegistry.run_projections()
            |> Enum.filter(&(Map.get(&1, "job_id") == request.job_id))

          response(%{"job_id" => request.job_id, "items" => items, "next_page_token" => nil})
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp with_json_bundle(request, callback) do
    Support.with_request_bundle(request.manifest_json, request.payloads, fn tmp_dir ->
      callback.(tmp_dir)
    end)
  end

  defp forward_call(owner, function, request, stream) do
    if MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 do
      raise GRPC.RPCError,
        status: GRPC.Status.failed_precondition(),
        message: "MN_FEDERATION_LOOP: forwarded request cannot be forwarded again"
    end

    FederationClient.call(owner, function, request)
  end

  defp respond_definition({:ok, definition}, :summary),
    do: response(JobProjection.summary(definition))

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
