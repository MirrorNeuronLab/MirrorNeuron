defmodule MirrorNeuron.Persistence.RedisStore.RecoveryIndex do
  @moduledoc "Repairs recovery evaluation indexes and expires terminal evaluations."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Recovery
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  @recovery_eval_statuses ["pending", "running", "blocked", "complete", "failed"]

  def repair_recovery_eval_indexes do
    case recovery_eval_index_ids() do
      {:ok, eval_ids} ->
        result =
          Enum.reduce(
            eval_ids,
            %{repaired_recovery_evals: 0, removed_stale_recovery_evals: 0},
            fn eval_id, acc ->
              case Recovery.fetch_recovery_eval(eval_id) do
                {:ok, eval} when is_map(eval) ->
                  if repair_recovery_eval_status_index(eval_id, Map.get(eval, "status")) do
                    Map.update!(acc, :repaired_recovery_evals, &(&1 + 1))
                  else
                    acc
                  end

                {:error, reason} ->
                  if Recovery.missing_recovery_eval?(eval_id, reason) or
                       Values.corrupt_json?(reason) do
                    if remove_stale_recovery_eval_index(eval_id) do
                      Map.update!(acc, :removed_stale_recovery_evals, &(&1 + 1))
                    else
                      acc
                    end
                  else
                    acc
                  end
              end
            end
          )

        {:ok, result}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp repair_recovery_eval_status_index(eval_id, status) do
    case Connection.transaction(Recovery.recovery_eval_status_index_commands(eval_id, status)) do
      {:ok, [count | rest]} when is_integer(count) ->
        count > 0 or Enum.any?(rest, fn value -> is_integer(value) and value > 0 end)

      _ ->
        false
    end
  end

  def sweep_recovery_eval_retention do
    ttl_seconds = RetentionPolicy.recovery_eval_ttl_seconds()

    # Terminal recovery payloads already receive a Redis TTL when their status is
    # persisted. Prune their set indexes after Redis expires the value instead of
    # downloading every payload and renewing its TTL on every retention pass.
    # Keeping this work in Redis also makes the network cost proportional to the
    # number of records actually removed, rather than the total recovery history.
    index_keys = [Keys.key("recovery", "evals") | Recovery.recovery_eval_status_index_keys()]
    complete_index = 5
    failed_index = 6

    script = """
    local ids = {}
    for _, index_key in ipairs(KEYS) do
      for _, eval_id in ipairs(redis.call("SMEMBERS", index_key)) do
        ids[eval_id] = true
      end
    end

    local eval_prefix = ARGV[1]
    local ttl_seconds = tonumber(ARGV[2]) or -1
    local deleted = {}
    local stale = {}

    for eval_id, _ in pairs(ids) do
      local eval_key = eval_prefix .. eval_id
      local exists = redis.call("EXISTS", eval_key) == 1
      local terminal =
        redis.call("SISMEMBER", KEYS[#{complete_index}], eval_id) == 1 or
        redis.call("SISMEMBER", KEYS[#{failed_index}], eval_id) == 1
      local deleted_now = false

      if exists and terminal then
        if ttl_seconds <= 0 then
          redis.call("DEL", eval_key)
          exists = false
          deleted_now = true
          table.insert(deleted, eval_id)
        elseif redis.call("TTL", eval_key) == -1 then
          redis.call("EXPIRE", eval_key, ttl_seconds)
        end
      end

      if not exists then
        for _, index_key in ipairs(KEYS) do
          redis.call("SREM", index_key, eval_id)
        end

        if not deleted_now then
          table.insert(stale, eval_id)
        end
      end
    end

    table.sort(deleted)
    table.sort(stale)
    return {deleted, stale}
    """

    Connection.command([
      "EVAL",
      script,
      to_string(length(index_keys))
      | index_keys ++ [Keys.key("recovery", "eval") <> ":", to_string(ttl_seconds)]
    ])
    |> case do
      {:ok, [deleted_recovery_evals, stale_recovery_evals]}
      when is_list(deleted_recovery_evals) and is_list(stale_recovery_evals) ->
        {:ok,
         %{
           deleted_recovery_eval_count: length(deleted_recovery_evals),
           stale_recovery_eval_count: length(stale_recovery_evals),
           deleted_recovery_evals: deleted_recovery_evals,
           stale_recovery_evals: stale_recovery_evals
         }}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  defp recovery_eval_index_ids do
    index_keys = [Keys.key("recovery", "evals") | Recovery.recovery_eval_status_index_keys()]

    case Connection.pipeline(Enum.map(index_keys, &["SMEMBERS", &1])) do
      {:ok, results} ->
        {:ok,
         results
         |> Enum.flat_map(fn
           ids when is_list(ids) -> ids
           _ -> []
         end)
         |> Enum.uniq()
         |> Enum.sort()}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp remove_stale_recovery_eval_index(eval_id) do
    commands =
      [
        ["DEL", Keys.key("recovery", "eval", eval_id)],
        ["SREM", Keys.key("recovery", "evals"), eval_id]
        | Enum.map(@recovery_eval_statuses, fn status ->
            ["SREM", Keys.key("recovery", "evals", "status", status), eval_id]
          end)
      ]

    case Connection.transaction(commands) do
      {:ok, [_deleted, removed | _]} when is_integer(removed) -> removed > 0
      _ -> false
    end
  end
end
