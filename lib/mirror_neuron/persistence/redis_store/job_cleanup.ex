defmodule MirrorNeuron.Persistence.RedisStore.JobCleanup do
  @moduledoc "Deletes a run only after its owned storage and service cleanup succeed."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Artifacts.JobStore
  alias MirrorNeuron.Persistence.RedisStore.Jobs
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Services
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Persistence.RedisStore.Values

  @jobs_set "jobs"

  def delete_job(job_id, opts \\ []), do: do_delete_job(job_id, opts)

  defp do_delete_job(job_id, opts) do
    with {:ok, job_map} <- job_for_cleanup(job_id),
         :ok <- Services.delete_service_instances(job_id: job_id),
         :ok <- cleanup_shared_storage(job_id, job_map),
         :ok <- JobStore.cleanup_job(job_id),
         {:ok, agent_ids} <- Connection.command(["SMEMBERS", Keys.key("job", job_id, "agents")]),
         {:ok, delivery_keys} <- Connection.command(["SMEMBERS", Keys.delivery_index_key(job_id)]),
         {:ok, delivery_receipts} <-
           Connection.scan_keys(Keys.key("job", job_id, "delivery", "*", "*")),
         :ok <-
           delete_job_redis_keys(job_id, agent_ids, delivery_keys ++ delivery_receipts, opts) do
      :ok
    end
  end

  defp cleanup_shared_storage(job_id, job_map) do
    SharedStorage.cleanup_job(job_id, job_map)
  end

  defp job_for_cleanup(job_id) do
    case Jobs.fetch_job(job_id) do
      {:ok, job} when is_map(job) ->
        {:ok, job}

      {:error, reason} ->
        if reason == "job #{job_id} was not found", do: {:ok, nil}, else: {:error, reason}
    end
  end

  defp delete_job_redis_keys(job_id, agent_ids, delivery_keys, opts) do
    job_keys =
      [
        Keys.key("job", job_id),
        Keys.key("job", job_id, "summary"),
        Keys.key("job", job_id, "retry_checkpoint"),
        Keys.key("job", job_id, "events"),
        Keys.key("job", job_id, "agents"),
        Keys.key("lease", "job:#{job_id}"),
        Keys.delivery_index_key(job_id)
      ]

    fence_keys =
      if Keyword.get(opts, :preserve_cancellation_fence, false) do
        []
      else
        [Keys.key("job", job_id, "guard"), Keys.key("lease", "job:#{job_id}", "epoch")]
      end

    keys =
      job_keys ++
        fence_keys ++
        Enum.map(agent_ids, &Keys.key("job", job_id, "agent", &1)) ++
        Enum.map(agent_ids, &Keys.key("job", job_id, "agent_summary", &1)) ++ delivery_keys

    with {:ok, results} <-
           Connection.transaction([
             ["DEL" | keys],
             ["SREM", Keys.key(@jobs_set), job_id]
           ]),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- Connection.wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end
end
