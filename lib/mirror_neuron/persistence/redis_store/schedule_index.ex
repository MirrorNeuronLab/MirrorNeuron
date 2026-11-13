defmodule MirrorNeuron.Persistence.RedisStore.ScheduleIndex do
  @moduledoc "Reclaims missing schedules and their lease metadata with existence checks."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  @schedules_set "schedules"
  @schedule_due_zset "schedule:due"

  def sweep_schedule_index do
    with {:ok, schedule_ids} <- raw_schedule_index_ids(),
         {:ok, existence} <- schedule_existence(schedule_ids),
         :ok <- Results.expect_no_redis_errors(existence),
         stale <- stale_schedule_ids(schedule_ids, existence),
         {:ok, removed} <- purge_stale_schedules(stale) do
      removed = Enum.sort(removed)
      {:ok, %{stale_schedule_count: length(removed), stale_schedules: removed}}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  def raw_schedule_index_ids do
    with {:ok, index_results} <-
           Connection.pipeline([
             ["SMEMBERS", Keys.key(@schedules_set)],
             ["ZRANGE", Keys.key(@schedule_due_zset), "0", "-1"]
           ]),
         :ok <- Results.expect_no_redis_errors(index_results) do
      {:ok, index_results |> Enum.flat_map(& &1) |> Enum.uniq() |> Enum.sort()}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  defp schedule_existence([]), do: {:ok, []}

  defp schedule_existence(schedule_ids) do
    Connection.pipeline(Enum.map(schedule_ids, &["EXISTS", Keys.key("schedule", &1)]))
  end

  defp stale_schedule_ids(schedule_ids, existence) do
    schedule_ids
    |> Enum.zip(existence)
    |> Enum.flat_map(fn
      {schedule_id, 0} -> [schedule_id]
      {_schedule_id, 1} -> []
    end)
  end

  defp purge_stale_schedules(schedule_ids) do
    Enum.reduce_while(schedule_ids, {:ok, []}, fn schedule_id, {:ok, removed} ->
      case purge_missing_schedule(schedule_id) do
        {:ok, 1} -> {:cont, {:ok, [schedule_id | removed]}}
        {:ok, 0} -> {:cont, {:ok, removed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      {:error, _reason} = error -> error
    end
  end

  def purge_missing_schedule(schedule_id) do
    with {:ok, lease_keys} <- Connection.scan_keys(Keys.key("lease", "schedule:#{schedule_id}:*")) do
      script = """
      if redis.call("exists", KEYS[1]) ~= 0 then
        return 0
      end

      redis.call("srem", KEYS[2], ARGV[1])
      redis.call("zrem", KEYS[3], ARGV[1])

      for index = 4, #KEYS do
        redis.call("del", KEYS[index])
      end

      return 1
      """

      keys =
        [
          Keys.key("schedule", schedule_id),
          Keys.key(@schedules_set),
          Keys.key(@schedule_due_zset)
          | lease_keys
        ]

      case Connection.command(["EVAL", script, to_string(length(keys)) | keys ++ [schedule_id]]) do
        {:ok, result} when result in [0, 1] ->
          with :ok <- Connection.maybe_wait_for_deleted_keys(result), do: {:ok, result}

        {:error, reason} ->
          {:error, Values.format_reason(reason)}

        other ->
          {:error, Values.format_reason(other)}
      end
    end
  end
end
