defmodule MirrorNeuron.Persistence.RedisStore.Recovery do
  @moduledoc "Recovery evaluation records, status queries and retention policy."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  @recovery_eval_statuses ["pending", "running", "blocked", "complete", "failed"]
  @terminal_recovery_eval_statuses ["complete", "failed"]
  @recovery_eval_fields [
    "eval_id",
    "job_id",
    "trigger",
    "status",
    "reason",
    "failed_node",
    "affected_agents",
    "attempt",
    "history",
    "created_at",
    "updated_at",
    "started_at",
    "completed_at",
    "result",
    "block_reason",
    "wait_until",
    "wake_reason"
  ]

  def persist_recovery_eval(eval_id, eval_map) do
    eval =
      eval_map
      |> Values.stringify_map()
      |> compact_recovery_eval()
      |> Map.put("eval_id", eval_id)
      |> Map.put_new("created_at", Values.timestamp())
      |> Map.put("updated_at", Values.timestamp())

    with {:ok, results} <-
           Connection.transaction(
             [
               ["SET", Keys.key("recovery", "eval", eval_id), Jason.encode!(eval)],
               ["SADD", Keys.key("recovery", "evals"), eval_id]
               | recovery_eval_status_index_commands(eval_id, Map.get(eval, "status"))
             ] ++ recovery_eval_retention_commands(eval_id, Map.get(eval, "status"))
           ),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- Connection.wait_for_replicas() do
      {:ok, eval}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def fetch_recovery_eval(eval_id) do
    case Connection.command(["GET", Keys.key("recovery", "eval", eval_id)]) do
      {:ok, nil} -> {:error, "recovery eval #{eval_id} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def list_recovery_evals(statuses \\ :all)

  def list_recovery_evals(:all) do
    case Connection.command(["SMEMBERS", Keys.key("recovery", "evals")]) do
      {:ok, eval_ids} ->
        fetch_recovery_evals(eval_ids)

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def list_recovery_evals(statuses) do
    statuses =
      statuses
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case recovery_eval_ids_by_status(statuses) do
      {:ok, eval_ids} -> fetch_recovery_evals(eval_ids)
      {:error, reason} -> {:error, reason}
    end
  end

  def update_recovery_eval(eval_id, updates) do
    existing =
      case fetch_recovery_eval(eval_id) do
        {:ok, eval} when is_map(eval) -> eval
        _ -> %{"eval_id" => eval_id}
      end

    eval =
      existing
      |> Map.merge(Values.stringify_map(updates))
      |> Map.put("eval_id", eval_id)
      |> Map.put("updated_at", Values.timestamp())

    persist_recovery_eval(eval_id, eval)
  end

  defp fetch_recovery_evals([]), do: {:ok, []}

  defp fetch_recovery_evals(eval_ids) do
    keys =
      eval_ids
      |> Enum.sort()
      |> Enum.map(&Keys.key("recovery", "eval", &1))

    case Connection.command(["MGET" | keys]) do
      {:ok, encoded_evals} ->
        encoded_evals
        |> Values.decode_json_items()
        |> Enum.sort_by(&Map.get(&1, "created_at", ""))
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp recovery_eval_ids_by_status([]), do: {:ok, []}

  defp recovery_eval_ids_by_status([status]) do
    case Connection.command(["SMEMBERS", Keys.key("recovery", "evals", "status", status)]) do
      {:ok, eval_ids} -> {:ok, eval_ids}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp recovery_eval_ids_by_status(statuses) do
    keys = Enum.map(statuses, &Keys.key("recovery", "evals", "status", &1))

    case Connection.command(["SUNION" | keys]) do
      {:ok, eval_ids} -> {:ok, eval_ids}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp compact_recovery_eval(eval) when is_map(eval), do: Map.take(eval, @recovery_eval_fields)

  defp compact_recovery_eval(eval), do: eval

  defp recovery_eval_retention_commands(eval_id, status) do
    eval_key = Keys.key("recovery", "eval", eval_id)

    if terminal_recovery_eval_status?(status) do
      RetentionPolicy.maybe_expire_key_command(
        eval_key,
        RetentionPolicy.recovery_eval_ttl_seconds()
      )
    else
      [["PERSIST", eval_key]]
    end
  end

  defp terminal_recovery_eval_status?(status),
    do: to_string(status || "") in @terminal_recovery_eval_statuses

  def missing_recovery_eval?(eval_id, reason),
    do: reason == "recovery eval #{eval_id} was not found"

  def recovery_eval_status_index_keys do
    Enum.map(@recovery_eval_statuses, &Keys.key("recovery", "evals", "status", &1))
  end

  def recovery_eval_status_index_commands(eval_id, status) do
    status = recovery_eval_status(status)

    [
      ["SADD", Keys.key("recovery", "evals", "status", status), eval_id]
      | Enum.map(@recovery_eval_statuses -- [status], fn old_status ->
          ["SREM", Keys.key("recovery", "evals", "status", old_status), eval_id]
        end)
    ]
  end

  defp recovery_eval_status(nil), do: "pending"

  defp recovery_eval_status(status), do: to_string(status)
end
