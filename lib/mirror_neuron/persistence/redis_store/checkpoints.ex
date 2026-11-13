defmodule MirrorNeuron.Persistence.RedisStore.Checkpoints do
  @moduledoc "Run start requests, retained retry checkpoints and attempt state cleanup."

  alias MirrorNeuron.Artifacts.BlobRef
  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Jobs
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  def fetch_run_start_request(identity) do
    case Connection.command(["GET", Keys.key("run-start-request", identity)]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def persist_run_start_request(identity, request) do
    with {:ok, "OK"} <-
           Connection.command([
             "SET",
             Keys.key("run-start-request", identity),
             Jason.encode!(request)
           ]),
         :ok <- Connection.wait_for_replicas(),
         do: {:ok, request}
  end

  @doc false
  def persist_run_checkpoint(job_id, checkpoint, epoch) do
    script = """
    local guard = redis.call('GET', KEYS[1])
    if not guard then return -1 end
    guard = cjson.decode(guard)
    if tonumber(guard.lease_epoch) ~= tonumber(ARGV[2]) or
       guard.status == 'cancelling' or guard.status == 'cancelled' then return -1 end
    redis.call('SET', KEYS[2], ARGV[1])
    return 1
    """

    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, 1} <-
           Connection.command([
             "EVAL",
             script,
             "2",
             Keys.key("job", job_id, "guard"),
             Keys.key("job", job_id, "retry_checkpoint"),
             Jason.encode!(checkpoint),
             to_string(epoch)
           ]) do
      Connection.wait_for_replicas()
    else
      {:ok, -1} -> {:error, :stale_checkpoint_epoch}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def fetch_run_checkpoint(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, encoded} when is_binary(encoded) <-
           Connection.command(["GET", Keys.key("job", job_id, "retry_checkpoint")]),
         {:ok, checkpoint} <- Jason.decode(encoded) do
      {:ok, checkpoint}
    else
      {:ok, nil} -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def discard_run_checkpoint(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, _} <- Connection.command(["DEL", Keys.key("job", job_id, "retry_checkpoint")]),
         {:ok, _} <- Jobs.persist_terminal_job(job_id, %{"retry_checkpoint_discarded" => true}) do
      :ok
    end
  end

  def retained_checkpoint_storage do
    with {:ok, ids} <- Jobs.list_job_ids() do
      Enum.reduce(
        ids,
        %{"checkpoint_count" => 0, "checkpoint_bytes" => 0, "referenced_artifact_bytes" => 0},
        fn id, acc ->
          case fetch_run_checkpoint(id) do
            {:ok, checkpoint} ->
              artifact_bytes =
                checkpoint
                |> BlobRef.collect()
                |> Enum.map(&Map.get(&1, "size_bytes", 0))
                |> Enum.sum()

              artifact_bytes =
                artifact_bytes +
                  Enum.reduce(get_in(checkpoint, ["artifacts", "inventory"]) || [], 0, fn entry,
                                                                                          total ->
                    total + (entry["size_bytes"] || 0)
                  end)

              acc
              |> Map.update!("checkpoint_count", &(&1 + 1))
              |> Map.update!("checkpoint_bytes", &(&1 + byte_size(Jason.encode!(checkpoint))))
              |> Map.update!("referenced_artifact_bytes", &(&1 + artifact_bytes))

            _ ->
              acc
          end
        end
      )
    else
      _ -> %{"unavailable" => true}
    end
  end

  @doc false
  def clear_job_attempt_state(job_id) do
    with {:ok, agent_ids} <- Connection.command(["SMEMBERS", Keys.key("job", job_id, "agents")]),
         {:ok, delivery_keys} <- Connection.command(["SMEMBERS", Keys.delivery_index_key(job_id)]),
         attempt_keys <-
           Enum.reject(
             delivery_keys,
             &MirrorNeuron.Persistence.DeliveryStore.protected_retention_key?(job_id, &1)
           ),
         {:ok, delivery_receipts} <-
           Connection.scan_keys(Keys.key("job", job_id, "delivery", "*", "*")),
         keys <-
           [Keys.key("job", job_id, "agents")] ++
             Enum.flat_map(agent_ids, fn agent_id ->
               [
                 Keys.key("job", job_id, "agent", agent_id),
                 Keys.key("job", job_id, "agent_summary", agent_id)
               ]
             end) ++ attempt_keys ++ delivery_receipts,
         cleanup_index <-
           if(attempt_keys == [],
             do: [],
             else: [["SREM", Keys.delivery_index_key(job_id) | attempt_keys]]
           ),
         {:ok, results} <- Connection.transaction([["DEL" | Enum.uniq(keys)]] ++ cleanup_index),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- Connection.wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end
end
