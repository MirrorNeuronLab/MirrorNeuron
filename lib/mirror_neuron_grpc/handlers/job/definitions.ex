defmodule MirrorNeuron.Grpc.Handlers.Job.Definitions do
  @moduledoc "Handles stable Job definition reads, mutations and bundle staging."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Cluster.FederationRegistry
  alias MirrorNeuron.Runtime.Idempotency
  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Handlers.Support

  def create_job(request, stream) do
    owner_node = Support.blank_to_nil(request.owner_node) || to_string(NodeAdapter.self())

    if owner_node != to_string(NodeAdapter.self()) do
      Remote.forward_call(owner_node, :create_job, %{request | owner_node: owner_node}, stream)
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
    |> Encoding.respond_definition(:summary)
  end

  def get_job(request, stream) do
    case MirrorNeuron.get_job(request.job_id) do
      {:ok, %{"status" => "relocated", "owner_node" => owner}} ->
        Remote.forward_call(owner, :get_job, request, stream)

      {:ok, definition} ->
        Encoding.response(JobProjection.detail(definition))

      _error ->
        if MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 do
          Encoding.respond({:error, :not_found})
        else
          Remote.remote_read(
            request.job_id,
            &Remote.remote_job_owner/1,
            :get_job,
            request,
            stream
          )
        end
    end
  end

  def list_jobs(request, _stream) do
    case MirrorNeuron.list_stable_jobs_page(
           include_archived: request.include_archived,
           page_size: Encoding.page_size(request.page_size),
           page_token: Support.blank_to_nil(request.page_token)
         ) do
      {:ok, jobs, next_page_token} ->
        items =
          if Map.get(request, :local_only, false) do
            JobProjection.summaries(jobs)
          else
            remote_jobs =
              FederationRegistry.projections()
              |> Enum.reject(
                &(not request.include_archived and Map.get(&1, "status") == "archived")
              )

            JobProjection.summaries(jobs) ++ remote_jobs
          end

        Encoding.response(%{
          "items" => Enum.uniq_by(items, &Map.get(&1, "job_id")),
          "next_page_token" => next_page_token
        })

      error ->
        Encoding.respond(error)
    end
  end

  def update_job(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil -> update_local_job(request)
      owner -> Remote.forward_call(owner, :update_job, request, stream)
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

    Encoding.respond_definition(result, :summary)
  end

  def archive_job(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil ->
        request.job_id
        |> MirrorNeuron.archive_job(expected_revision: request.expected_revision)
        |> Encoding.respond_definition(:summary)

      owner ->
        Remote.forward_archive_or_queue(owner, request, stream)
    end
  end

  def reset_job_data(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil ->
        request.job_id |> MirrorNeuron.reset_job_data() |> Encoding.respond_definition(:summary)

      owner ->
        Remote.forward_call(owner, :reset_job_data, request, stream)
    end
  end

  def delete_job(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil -> delete_local_job(request)
      owner -> Remote.forward_delete_or_queue(owner, request, stream)
    end
  end

  defp delete_local_job(request) do
    case MirrorNeuron.delete_stable_job(request.job_id,
           confirmed: request.confirmed,
           expected_revision: request.expected_revision
         ) do
      {:ok, retired_resources} ->
        Encoding.response(%{
          "job_id" => request.job_id,
          "status" => "deleted",
          "retired_definition_resources" => retired_resources
        })

      error ->
        Encoding.respond(error)
    end
  end

  defp with_json_bundle(request, callback) do
    Support.with_request_bundle(request.manifest_json, request.payloads, fn tmp_dir ->
      callback.(tmp_dir)
    end)
  end
end
