defmodule MirrorNeuron.Persistence.RedisStore.JobIndex do
  @moduledoc "Repairs job discovery indexes from durable root records."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.RecoveryIndex
  alias MirrorNeuron.Persistence.RedisStore.Values

  @jobs_set "jobs"

  def repair_recovery_indexes do
    with {:ok, redis_keys} <- Connection.scan_keys(Keys.key("job", "*")),
         {:ok, indexed_job_ids} <- raw_job_ids(),
         {:ok, job_repair} <- repair_job_index(redis_keys, indexed_job_ids),
         {:ok, eval_repair} <- RecoveryIndex.repair_recovery_eval_indexes(),
         :ok <- Connection.wait_for_replicas() do
      {:ok,
       job_repair
       |> Map.put(:repaired_agents, 0)
       |> Map.put(:removed_stale_agents, 0)
       |> Map.merge(eval_repair)}
    end
  end

  defp repair_job_index(redis_keys, indexed_job_ids) do
    root_job_ids =
      redis_keys
      |> Enum.flat_map(&Keys.root_job_id_from_key/1)
      |> Enum.uniq()

    indexed_job_ids = Enum.uniq(indexed_job_ids)
    indexed_job_set = MapSet.new(indexed_job_ids)

    repaired_jobs =
      root_job_ids
      |> Enum.filter(&(json_key_status(Keys.key("job", &1)) == :valid))
      |> Enum.reject(&MapSet.member?(indexed_job_set, &1))
      |> Enum.count(fn job_id ->
        case Connection.command(["SADD", Keys.key(@jobs_set), job_id]) do
          {:ok, count} when is_integer(count) -> count > 0
          _ -> false
        end
      end)

    removed_stale_jobs =
      indexed_job_ids
      |> Enum.filter(&(json_key_status(Keys.key("job", &1)) in [:missing, :corrupt]))
      |> Enum.count(fn job_id ->
        case Connection.command(["SREM", Keys.key(@jobs_set), job_id]) do
          {:ok, count} when is_integer(count) -> count > 0
          _ -> false
        end
      end)

    {:ok, %{repaired_jobs: repaired_jobs, removed_stale_jobs: removed_stale_jobs}}
  end

  defp json_key_status(redis_key) do
    case Connection.command(["GET", redis_key]) do
      {:ok, encoded} when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, value} when is_map(value) -> :valid
          _ -> :corrupt
        end

      {:ok, nil} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp raw_job_ids do
    case Connection.command(["SMEMBERS", Keys.key(@jobs_set)]) do
      {:ok, job_ids} -> {:ok, job_ids}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end
end
