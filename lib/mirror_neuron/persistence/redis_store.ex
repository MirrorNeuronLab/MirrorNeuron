defmodule MirrorNeuron.Persistence.RedisStore do
  alias MirrorNeuron.Artifacts.{BlobRef, JobStore, SharedStorage}
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Config
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Persistence.DiskCheckpoint

  require Logger

  @jobs_set "jobs"
  @deployments_set "deployments"
  @schedules_set "schedules"
  @schedule_due_zset "schedule:due"
  @trigger_events_list "trigger:events"
  @terminal_statuses ["completed", "failed", "cancelled"]
  @default_terminal_job_ttl_seconds 7 * 24 * 60 * 60
  @default_event_ttl_seconds 7 * 24 * 60 * 60
  @default_event_max_count 10_000
  @default_agent_snapshot_ttl_seconds 7 * 24 * 60 * 60
  @default_bundle_archive_ttl_seconds 7 * 24 * 60 * 60
  @default_blob_ref_ttl_seconds 7 * 24 * 60 * 60
  @default_recovery_eval_ttl_seconds 24 * 60 * 60
  @delivery_consumer_group "mirror_neuron_agents"
  @recovery_eval_statuses ["pending", "running", "blocked", "complete", "failed"]
  @terminal_recovery_eval_statuses ["complete", "failed"]
  @service_index_fields [
    {:name, "name"},
    {:job_id, "job"},
    {:node, "node"},
    {:agent_id, "agent"}
  ]
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

  @doc false
  def enqueue_delivery(job_id, agent_id, message, opts) do
    message_id = MirrorNeuron.Message.id(message)
    encoded = Jason.encode!(message)
    digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
    now_ms = Keyword.fetch!(opts, :now_ms)
    deadline_ms = Keyword.fetch!(opts, :deadline_ms)
    pending_ttl_seconds = Keyword.fetch!(opts, :pending_ttl_seconds)
    stream_ttl_seconds = Keyword.fetch!(opts, :stream_ttl_seconds)
    max_pending_agent = Keyword.fetch!(opts, :max_pending_agent)
    max_pending_job = Keyword.fetch!(opts, :max_pending_job)

    receipt_key = delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = delivery_stream_key(job_id, agent_id)
    agent_count_key = delivery_agent_count_key(job_id, agent_id)
    job_count_key = delivery_job_count_key(job_id)
    index_key = delivery_index_key(job_id)

    script = """
    if redis.call("exists", KEYS[1]) == 1 then
      local existing_digest = redis.call("hget", KEYS[1], "digest")
      local status = redis.call("hget", KEYS[1], "status") or "unknown"
      local stream_id = redis.call("hget", KEYS[1], "stream_id") or ""
      if existing_digest ~= ARGV[2] then
        return {"conflict", status, stream_id}
      end
      return {"duplicate", status, stream_id}
    end

    local agent_count = tonumber(redis.call("get", KEYS[3]) or "0")
    local job_count = tonumber(redis.call("get", KEYS[4]) or "0")
    if agent_count >= tonumber(ARGV[8]) then
      return {"agent_full", tostring(agent_count), ""}
    end
    if job_count >= tonumber(ARGV[9]) then
      return {"job_full", tostring(job_count), ""}
    end

    local stream_id = redis.call(
      "xadd", KEYS[2], "*", "message_id", ARGV[1], "payload", ARGV[3]
    )
    redis.call(
      "hset", KEYS[1],
      "message_id", ARGV[1],
      "digest", ARGV[2],
      "status", "queued",
      "stream_id", stream_id,
      "attempts", "0",
      "deadline_ms", ARGV[5],
      "enqueued_at_ms", ARGV[4]
    )
    redis.call("expire", KEYS[1], ARGV[6])
    redis.call("expire", KEYS[2], ARGV[7])
    redis.call("incr", KEYS[3])
    redis.call("expire", KEYS[3], ARGV[7])
    redis.call("incr", KEYS[4])
    redis.call("expire", KEYS[4], ARGV[7])
    redis.call("sadd", KEYS[5], KEYS[1], KEYS[2], KEYS[3], KEYS[4])
    redis.call("expire", KEYS[5], ARGV[7])
    return {"queued", "queued", stream_id}
    """

    args = [
      "EVAL",
      script,
      "5",
      receipt_key,
      stream_key,
      agent_count_key,
      job_count_key,
      index_key,
      message_id,
      digest,
      encoded,
      to_string(now_ms),
      to_string(deadline_ms),
      to_string(pending_ttl_seconds),
      to_string(stream_ttl_seconds),
      to_string(max_pending_agent),
      to_string(max_pending_job)
    ]

    case command(args) do
      {:ok, ["queued", _status, stream_id]} ->
        with :ok <- wait_for_replicas(),
             do: {:ok, %{status: :queued, stream_id: stream_id, message_id: message_id}}

      {:ok, ["duplicate", status, stream_id]} ->
        {:ok,
         %{
           status: :duplicate,
           delivery_status: status,
           stream_id: stream_id,
           message_id: message_id
         }}

      {:ok, ["conflict", status, _stream_id]} ->
        {:error, {:message_id_conflict, message_id, status}}

      {:ok, ["agent_full", count, _stream_id]} ->
        {:error, {:delivery_backpressure, :agent, parse_redis_integer(count)}}

      {:ok, ["job_full", count, _stream_id]} ->
        {:error, {:delivery_backpressure, :job, parse_redis_integer(count)}}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_enqueue_result, other}}
    end
  end

  @doc false
  def read_deliveries(job_id, agent_id, consumer, opts) do
    stream_key = delivery_stream_key(job_id, agent_id)
    lease_ms = Keyword.fetch!(opts, :lease_ms)
    max_attempts = Keyword.fetch!(opts, :max_attempts)
    now_ms = Keyword.fetch!(opts, :now_ms)
    count = Keyword.get(opts, :count, 1)

    with :ok <-
           maybe_ensure_delivery_group(
             stream_key,
             Keyword.fetch!(opts, :stream_ttl_seconds),
             Keyword.get(opts, :ensure_group, true)
           ),
         {:ok, claimed} <-
           maybe_claim_stale_deliveries(
             stream_key,
             consumer,
             lease_ms,
             count,
             Keyword.get(opts, :claim_stale, true)
           ),
         {:ok, entries} <- read_new_deliveries(stream_key, consumer, count - length(claimed)) do
      (claimed ++ entries)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case prepare_delivery(job_id, agent_id, consumer, entry, now_ms, max_attempts) do
          {:ok, delivery} -> {:cont, {:ok, [delivery | acc]}}
          {:discard, discard} -> {:cont, {:ok, [discard | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, deliveries} -> {:ok, Enum.reverse(deliveries)}
        error -> error
      end
    end
  end

  @doc false
  def ack_delivery(job_id, agent_id, consumer, stream_id, message_id, ack_ttl_seconds) do
    receipt_key = delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = delivery_stream_key(job_id, agent_id)

    script = """
    local status = redis.call("hget", KEYS[1], "status")
    if status ~= "acked" and status ~= "dead_letter" then
      redis.call("hset", KEYS[1], "status", "acked", "consumer", ARGV[1])
      local agent_count = tonumber(redis.call("get", KEYS[3]) or "0")
      local job_count = tonumber(redis.call("get", KEYS[4]) or "0")
      if agent_count > 0 then redis.call("decr", KEYS[3]) end
      if job_count > 0 then redis.call("decr", KEYS[4]) end
    end
    if redis.call("exists", KEYS[1]) == 1 then redis.call("expire", KEYS[1], ARGV[2]) end
    redis.call("srem", KEYS[5], KEYS[1])
    redis.call("xack", KEYS[2], ARGV[3], ARGV[4])
    redis.call("xdel", KEYS[2], ARGV[4])
    return 1
    """

    args = [
      "EVAL",
      script,
      "5",
      receipt_key,
      stream_key,
      delivery_agent_count_key(job_id, agent_id),
      delivery_job_count_key(job_id),
      delivery_index_key(job_id),
      consumer,
      to_string(ack_ttl_seconds),
      @delivery_consumer_group,
      stream_id
    ]

    case command(args) do
      {:ok, 1} -> wait_for_replicas()
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_ack_result, other}}
    end
  end

  @doc false
  def dead_letter_delivery(job_id, agent_id, stream_id, message_id, reason, ttl_seconds) do
    receipt_key = delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = delivery_stream_key(job_id, agent_id)

    script = """
    local status = redis.call("hget", KEYS[1], "status")
    if status ~= "acked" and status ~= "dead_letter" then
      local agent_count = tonumber(redis.call("get", KEYS[3]) or "0")
      local job_count = tonumber(redis.call("get", KEYS[4]) or "0")
      if agent_count > 0 then redis.call("decr", KEYS[3]) end
      if job_count > 0 then redis.call("decr", KEYS[4]) end
    end
    if redis.call("exists", KEYS[1]) == 1 then
      redis.call("hset", KEYS[1], "status", "dead_letter", "reason", ARGV[1])
      redis.call("expire", KEYS[1], ARGV[2])
    end
    redis.call("srem", KEYS[5], KEYS[1])
    redis.call("xack", KEYS[2], ARGV[3], ARGV[4])
    redis.call("xdel", KEYS[2], ARGV[4])
    return 1
    """

    args = [
      "EVAL",
      script,
      "5",
      receipt_key,
      stream_key,
      delivery_agent_count_key(job_id, agent_id),
      delivery_job_count_key(job_id),
      delivery_index_key(job_id),
      to_string(reason),
      to_string(ttl_seconds),
      @delivery_consumer_group,
      stream_id
    ]

    case command(args) do
      {:ok, 1} -> wait_for_replicas()
      {:error, command_reason} -> {:error, format_reason(command_reason)}
      other -> {:error, {:unexpected_delivery_dead_letter_result, other}}
    end
  end

  @doc false
  def renew_delivery(job_id, agent_id, consumer, stream_id) do
    case command([
           "XCLAIM",
           delivery_stream_key(job_id, agent_id),
           @delivery_consumer_group,
           consumer,
           "0",
           stream_id,
           "IDLE",
           "0",
           "JUSTID"
         ]) do
      {:ok, [^stream_id]} -> :ok
      {:ok, []} -> {:error, :delivery_not_pending}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_renew_result, other}}
    end
  end

  @doc false
  def retry_delivery(job_id, agent_id, consumer, stream_id, delay_ms, lease_ms) do
    idle_ms = max(lease_ms - delay_ms, 0)
    stream_key = delivery_stream_key(job_id, agent_id)

    case command([
           "XCLAIM",
           stream_key,
           @delivery_consumer_group,
           consumer,
           "0",
           stream_id,
           "IDLE",
           to_string(idle_ms),
           "JUSTID"
         ]) do
      {:ok, [^stream_id]} -> :ok
      {:ok, []} -> {:error, :delivery_not_pending}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_retry_result, other}}
    end
  end

  @doc false
  def fetch_delivery_receipt(job_id, agent_id, message_id) do
    case command(["HGETALL", delivery_receipt_key(job_id, agent_id, message_id)]) do
      {:ok, []} -> {:error, :not_found}
      {:ok, values} -> {:ok, values |> pairs_to_map() |> parse_delivery_receipt()}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  @doc false
  def delivery_pending_count(job_id, agent_id) do
    case command(["GET", delivery_agent_count_key(job_id, agent_id)]) do
      {:ok, nil} -> {:ok, 0}
      {:ok, count} -> {:ok, parse_redis_integer(count)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  @doc false
  def expire_job_deliveries(job_id, ttl_seconds) do
    index_key = delivery_index_key(job_id)

    with {:ok, keys} <- command(["SMEMBERS", index_key]),
         commands <- Enum.map([index_key | keys], &["EXPIRE", &1, to_string(ttl_seconds)]),
         {:ok, _results} <- pipeline(commands) do
      :ok
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_job(job_id, job_map) do
    encoded = Jason.encode!(job_map)
    encoded_summary = Jason.encode!(job_summary(job_id, job_map))

    with :ok <- validate_job_lease_epoch(job_id, job_map),
         :ok <- persist_disk_job(job_id, job_map),
         {:ok, results} <-
           transaction([
             ["SET", key("job", job_id), encoded],
             ["SET", key("job", job_id, "summary"), encoded_summary],
             ["SADD", key(@jobs_set), job_id]
           ]),
         :ok <- expect_persist_job_results(results),
         :ok <- apply_job_retention(job_id, job_map),
         :ok <- wait_for_replicas(),
         :ok <- cleanup_terminal_disk_checkpoint(job_id, job_map) do
      {:ok, job_map}
    end
  end

  def persist_terminal_job(job_id, updates, defaults \\ %{}) do
    existing =
      case fetch_job(job_id) do
        {:ok, job} when is_map(job) -> job
        _ -> %{}
      end

    job_map =
      defaults
      |> Map.merge(existing)
      |> Map.merge(updates)
      |> Map.put("job_id", job_id)
      |> Map.put_new("submitted_at", timestamp())
      |> Map.put("updated_at", timestamp())

    persist_job(job_id, job_map)
  end

  def fetch_job(job_id) do
    case command(["GET", key("job", job_id)]) do
      {:ok, nil} -> {:error, "job #{job_id} was not found"}
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_job_ids do
    case command(["SMEMBERS", key(@jobs_set)]) do
      {:ok, job_ids} -> {:ok, Enum.sort(compact_legacy_job_ids(job_ids))}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_jobs do
    with {:ok, job_ids} <- list_job_ids() do
      fetch_jobs(job_ids)
    end
  end

  def list_job_summaries do
    with {:ok, job_ids} <- list_job_ids() do
      fetch_job_summaries(job_ids)
    end
  end

  def persist_schedule(schedule_id, schedule_map) do
    schedule = prepare_schedule(schedule_id, schedule_map)

    commands =
      [
        ["SET", key("schedule", schedule_id), Jason.encode!(schedule)],
        ["SADD", key(@schedules_set), schedule_id],
        ["ZREM", key(@schedule_due_zset), schedule_id]
      ] ++ schedule_due_commands(schedule)

    with {:ok, results} <- transaction(commands),
         :ok <- expect_first_result(results, fn value -> value == "OK" end),
         :ok <- wait_for_replicas() do
      {:ok, schedule}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def persist_schedule_fenced(schedule_id, schedule_map, lease_name, owner_id, epoch) do
    schedule = prepare_schedule(schedule_id, schedule_map)
    due_score = schedule_due_score(schedule)

    script = """
    if redis.call("get", KEYS[1]) ~= ARGV[1] then
      return 0
    end

    redis.call("set", KEYS[2], ARGV[2])
    redis.call("sadd", KEYS[3], ARGV[3])
    redis.call("zrem", KEYS[4], ARGV[3])

    if ARGV[4] ~= "" then
      redis.call("zadd", KEYS[4], ARGV[4], ARGV[3])
    end

    return 1
    """

    args = [
      "EVAL",
      script,
      "4",
      key("lease", lease_name),
      key("schedule", schedule_id),
      key(@schedules_set),
      key(@schedule_due_zset),
      fenced_lease_value(owner_id, epoch),
      Jason.encode!(schedule),
      schedule_id,
      due_score
    ]

    case command(args) do
      {:ok, 1} ->
        with :ok <- wait_for_replicas(), do: {:ok, schedule}

      {:ok, 0} ->
        {:error, :not_owner}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def fetch_schedule(schedule_id) do
    case command(["GET", key("schedule", schedule_id)]) do
      {:ok, nil} ->
        {:error, "schedule #{schedule_id} was not found"}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, schedule} when is_map(schedule) -> {:ok, schedule}
          {:ok, _invalid} -> {:error, :invalid_schedule}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def list_schedules do
    with {:ok, schedule_ids} <- command(["SMEMBERS", key(@schedules_set)]) do
      fetch_indexed_schedules(schedule_ids)
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_due_schedules(now_iso) do
    score = schedule_score(now_iso)

    with {:ok, schedule_ids} <-
           command(["ZRANGEBYSCORE", key(@schedule_due_zset), "-inf", to_string(score)]) do
      fetch_indexed_schedules(schedule_ids)
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def delete_schedule(schedule_id) do
    with {:ok, results} <-
           transaction([
             ["DEL", key("schedule", schedule_id)],
             ["SREM", key(@schedules_set), schedule_id],
             ["ZREM", key(@schedule_due_zset), schedule_id]
           ]),
         :ok <- expect_no_redis_errors(results),
         :ok <- delete_schedule_lease_metadata(schedule_id),
         :ok <- wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def delete_schedule_fenced(schedule_id, lease_name, owner_id, epoch) do
    script = """
    if redis.call("get", KEYS[1]) ~= ARGV[1] then
      return 0
    end

    redis.call("del", KEYS[2])
    redis.call("srem", KEYS[3], ARGV[2])
    redis.call("zrem", KEYS[4], ARGV[2])
    redis.call("del", KEYS[1])
    redis.call("del", KEYS[5])
    return 1
    """

    case command([
           "EVAL",
           script,
           "5",
           key("lease", lease_name),
           key("schedule", schedule_id),
           key(@schedules_set),
           key(@schedule_due_zset),
           key("lease", lease_name, "epoch"),
           fenced_lease_value(owner_id, epoch),
           schedule_id
         ]) do
      {:ok, 1} ->
        with :ok <- delete_schedule_lease_metadata(schedule_id), do: wait_for_replicas()

      {:ok, 0} ->
        {:error, :not_owner}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def append_trigger_event(event_id, event_map) do
    event =
      event_map
      |> stringify_map()
      |> Map.put("event_id", event_id)
      |> Map.put_new("created_at", timestamp())

    encoded = Jason.encode!(event)

    with {:ok, _results} <-
           transaction([
             ["LPUSH", key(@trigger_events_list), encoded],
             ["LTRIM", key(@trigger_events_list), "0", "999"]
           ]),
         :ok <- wait_for_replicas() do
      {:ok, event}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def list_trigger_events(limit \\ 100) do
    stop = max(limit, 1) - 1

    case command(["LRANGE", key(@trigger_events_list), "0", to_string(stop)]) do
      {:ok, items} -> {:ok, decode_json_items(items)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_deployment(deployment_id, deployment_map) do
    deployment =
      deployment_map
      |> stringify_map()
      |> Map.put("deployment_id", deployment_id)
      |> Map.put_new("created_at", timestamp())
      |> Map.put("updated_at", timestamp())

    deployment_key = Map.get(deployment, "deployment_key")

    script = """
    local existing = redis.call("get", KEYS[1])

    if existing then
      local ok, decoded = pcall(cjson.decode, existing)

      if not ok or type(decoded) ~= "table" or tostring(decoded["deployment_id"]) ~= ARGV[1] then
        return redis.error_reply("invalid existing deployment " .. ARGV[1])
      end

      local old_key = decoded["deployment_key"]

      if type(old_key) == "string" and old_key ~= "" and old_key ~= ARGV[3] then
        local old_current = ARGV[4] .. old_key .. ":current"

        if redis.call("get", old_current) == ARGV[1] then
          redis.call("del", old_current)
        end

        redis.call("srem", ARGV[4] .. old_key .. ":deployments", ARGV[1])
      end
    end

    redis.call("set", KEYS[1], ARGV[2])
    redis.call("sadd", KEYS[2], ARGV[1])

    if ARGV[3] ~= "" then
      redis.call("set", ARGV[4] .. ARGV[3] .. ":current", ARGV[1])
      redis.call("sadd", ARGV[4] .. ARGV[3] .. ":deployments", ARGV[1])
    end

    return 1
    """

    args = [
      "EVAL",
      script,
      "2",
      key("deployment", deployment_id),
      key(@deployments_set),
      deployment_id,
      Jason.encode!(deployment),
      if(is_binary(deployment_key), do: deployment_key, else: ""),
      key("deployment", "key", "")
    ]

    case command(args) do
      {:ok, 1} ->
        with :ok <- wait_for_replicas(), do: {:ok, deployment}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, format_reason(other)}
    end
  end

  def fetch_deployment(deployment_id) do
    case command(["GET", key("deployment", deployment_id)]) do
      {:ok, nil} ->
        {:error, "deployment #{deployment_id} was not found"}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"deployment_id" => ^deployment_id} = deployment} -> {:ok, deployment}
          {:ok, deployment} when is_map(deployment) -> {:error, :invalid_deployment}
          {:ok, _invalid} -> {:error, :invalid_deployment}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def fetch_deployment_by_key(deployment_key) do
    current_key = key("deployment", "key", deployment_key, "current")

    case command(["GET", current_key]) do
      {:ok, nil} ->
        {:error, "deployment #{deployment_key} was not found"}

      {:ok, deployment_id} ->
        case fetch_deployment(deployment_id) do
          {:ok, %{"deployment_key" => ^deployment_key} = deployment} ->
            {:ok, deployment}

          {:ok, _mismatched} ->
            case remove_stale_deployment_pointer(current_key, deployment_key, deployment_id) do
              :ok -> {:error, "deployment #{deployment_key} was not found"}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            if missing_deployment?(deployment_id, reason) do
              case purge_missing_deployment(deployment_id) do
                :ok -> {:error, "deployment #{deployment_key} was not found"}
                {:error, cleanup_reason} -> {:error, cleanup_reason}
              end
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def fetch_deployment_ref(id_or_key) do
    case fetch_deployment(id_or_key) do
      {:ok, deployment} ->
        {:ok, deployment}

      {:error, reason} ->
        if missing_deployment?(id_or_key, reason),
          do: fetch_deployment_by_key(id_or_key),
          else: {:error, reason}
    end
  end

  def list_deployments do
    with {:ok, deployment_ids} <- command(["SMEMBERS", key(@deployments_set)]) do
      fetch_indexed_deployments(deployment_ids)
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_job_version(deployment_key, version, version_map) do
    version_id = to_string(version)

    version_record =
      version_map
      |> stringify_map()
      |> Map.put("deployment_key", deployment_key)
      |> Map.put("version", version_id)
      |> Map.put_new("created_at", timestamp())
      |> Map.put("updated_at", timestamp())

    commands = [
      [
        "SET",
        key("deployment", "key", deployment_key, "version", version_id),
        Jason.encode!(version_record)
      ],
      ["SADD", key("deployment", "key", deployment_key, "versions"), version_id]
    ]

    with {:ok, results} <- transaction(commands),
         :ok <- expect_first_result(results, fn value -> value == "OK" end),
         :ok <- wait_for_replicas() do
      {:ok, version_record}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def fetch_job_version(deployment_key, version) do
    version_id = to_string(version)

    case command(["GET", key("deployment", "key", deployment_key, "version", version_id)]) do
      {:ok, nil} ->
        {:error, "deployment #{deployment_key} version #{version_id} was not found"}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"deployment_key" => ^deployment_key, "version" => ^version_id} = record} ->
            {:ok, record}

          {:ok, record} when is_map(record) ->
            {:error, :invalid_deployment_version}

          {:ok, _invalid} ->
            {:error, :invalid_deployment_version}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def list_job_versions(deployment_key) do
    with {:ok, versions} <-
           command(["SMEMBERS", key("deployment", "key", deployment_key, "versions")]) do
      fetch_indexed_deployment_versions(deployment_key, versions)
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def append_event(job_id, event) do
    event_key = key("job", job_id, "events")

    with {:ok, encoded} <- Jason.encode(event),
         commands <- [["RPUSH", event_key, encoded] | event_retention_commands(event_key)],
         {:ok, results} <- pipeline(commands),
         :ok <- expect_first_result(results, &is_integer/1),
         :ok <- wait_for_replicas(),
         {:ok, _count} <- command(["PUBLISH", channel("events", job_id), encoded]) do
      {:ok, event}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def read_events(job_id, start \\ "0", stop \\ "-1") do
    case command(["LRANGE", key("job", job_id, "events"), to_string(start), to_string(stop)]) do
      {:ok, items} -> {:ok, Enum.map(items, &Jason.decode!/1)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def replace_job_events(job_id, events) when is_list(events) do
    event_key = key("job", job_id, "events")
    encoded_events = Enum.map(events, &Jason.encode!/1)

    commands =
      [["DEL", event_key]] ++
        Enum.map(encoded_events, fn encoded -> ["RPUSH", event_key, encoded] end) ++
        event_retention_commands(event_key)

    with {:ok, _results} <- transaction(commands),
         :ok <- wait_for_replicas() do
      {:ok, events}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def persist_agent(job_id, agent_id, snapshot) do
    encoded = Jason.encode!(snapshot)

    with :ok <- validate_agent_lease_epoch(job_id, snapshot),
         :ok <- persist_disk_agent(job_id, agent_id, snapshot),
         retention_commands <- agent_snapshot_retention_commands(job_id, agent_id),
         {:ok, results} <-
           transaction([
             ["SET", key("job", job_id, "agent", agent_id), encoded],
             ["SADD", key("job", job_id, "agents"), agent_id]
             | retention_commands
           ]),
         :ok <- expect_persist_agent_results(results),
         :ok <- wait_for_replicas() do
      {:ok, snapshot}
    end
  end

  def list_agents(job_id) do
    with {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]) do
      fetch_agents(job_id, Enum.sort(agent_ids))
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def fetch_agent(job_id, agent_id) do
    case command(["GET", key("job", job_id, "agent", agent_id)]) do
      {:ok, nil} -> {:error, "agent #{agent_id} was not found for job #{job_id}"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def repair_recovery_indexes do
    with {:ok, redis_keys} <- scan_keys(key("job", "*")),
         {:ok, indexed_job_ids} <- raw_job_ids(),
         {:ok, job_repair} <- repair_job_index(redis_keys, indexed_job_ids),
         {:ok, agent_repair} <- repair_agent_indexes(redis_keys, indexed_job_ids),
         {:ok, eval_repair} <- repair_recovery_eval_indexes(),
         :ok <- wait_for_replicas() do
      {:ok, job_repair |> Map.merge(agent_repair) |> Map.merge(eval_repair)}
    end
  end

  def delete_job(job_id) do
    DiskCheckpoint.with_job_lock(job_id, fn -> do_delete_job(job_id) end)
  end

  defp do_delete_job(job_id) do
    with {:ok, job_map} <- job_for_cleanup(job_id),
         :ok <- delete_service_instances(job_id: job_id),
         :ok <- cleanup_shared_storage(job_id, job_map),
         :ok <- JobStore.cleanup_job(job_id),
         :ok <- DiskCheckpoint.delete_job(job_id),
         {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]),
         {:ok, delivery_keys} <- command(["SMEMBERS", delivery_index_key(job_id)]),
         {:ok, delivery_receipts} <-
           scan_keys(key("job", job_id, "delivery", "*", "*")),
         :ok <-
           delete_job_redis_keys(job_id, agent_ids, delivery_keys ++ delivery_receipts) do
      :ok
    end
  end

  # A job record can outlive the runtime that submitted it. In that case its
  # shared-storage path may be valid on the former host but intentionally
  # unsafe from this runtime. Keep the path safety check, but do not let an
  # inaccessible artifact directory make a terminal job impossible to clear.
  defp cleanup_shared_storage(job_id, job_map) do
    case SharedStorage.cleanup_job(job_id, job_map) do
      :ok ->
        :ok

      {:error, reason}
      when reason == "mn_storage.submission_path is outside shared storage root" ->
        Logger.warning(
          "could not clean shared submission storage for #{job_id}; " <>
            "leaving it untouched and deleting the terminal job record: #{inspect(reason)}"
        )

        :ok

      error ->
        error
    end
  end

  defp job_for_cleanup(job_id) do
    case fetch_job(job_id) do
      {:ok, job} when is_map(job) ->
        {:ok, job}

      {:error, reason} ->
        if reason == "job #{job_id} was not found", do: {:ok, nil}, else: {:error, reason}
    end
  end

  defp delete_job_redis_keys(job_id, agent_ids, delivery_keys) do
    keys =
      [
        key("job", job_id),
        key("job", job_id, "summary"),
        key("job", job_id, "events"),
        key("job", job_id, "agents"),
        key("lease", "job:#{job_id}"),
        key("lease", "job:#{job_id}", "epoch"),
        delivery_index_key(job_id)
      ] ++
        Enum.map(agent_ids, &key("job", job_id, "agent", &1)) ++ delivery_keys

    with {:ok, results} <-
           transaction([
             ["DEL" | keys],
             ["SREM", key(@jobs_set), job_id]
           ]),
         :ok <- expect_no_redis_errors(results),
         :ok <- wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def refresh_disk_checkpoint(job_id) do
    DiskCheckpoint.with_job_lock(job_id, fn -> do_refresh_disk_checkpoint(job_id) end)
  end

  defp do_refresh_disk_checkpoint(job_id) do
    with {:ok, job} <- fetch_job(job_id),
         {:ok, agents} <- list_agents(job_id),
         :ok <- DiskCheckpoint.persist_job(job_id, job),
         :ok <- persist_disk_agents(job_id, agents),
         :ok <-
           DiskCheckpoint.prune_agents(
             job_id,
             Enum.map(agents, &(Map.get(&1, "agent_id") || Map.get(&1, "node_id")))
           ) do
      :ok
    end
  end

  def sweep_retention(opts \\ []) do
    ttl_seconds = Keyword.get(opts, :terminal_job_ttl_seconds, terminal_job_ttl_seconds())
    cleanup_job = Keyword.get(opts, :cleanup_job, fn _job_id -> :ok end)

    with {:ok, job_ids} <- list_job_ids(),
         {:ok, eval_result} <- sweep_recovery_eval_retention(),
         {:ok, blob_result} <- sweep_blob_ref_index(),
         {:ok, service_result} <- sweep_service_instance_index(),
         {:ok, schedule_result} <- sweep_schedule_index(),
         {:ok, trigger_result} <- sweep_legacy_trigger_event_keys(),
         {:ok, deployment_result} <- sweep_deployment_indexes() do
      result =
        Enum.reduce(job_ids, %{deleted_jobs: [], stale_job_ids: []}, fn job_id, acc ->
          case fetch_job(job_id) do
            {:ok, job} ->
              refresh_job_blob_refs(job)

              if terminal_job_expired?(job, ttl_seconds) do
                case run_retention_cleanup(cleanup_job, job_id, job) do
                  :ok ->
                    case delete_job(job_id) do
                      :ok ->
                        Map.update!(acc, :deleted_jobs, &[job_id | &1])

                      {:error, reason} ->
                        Logger.warning(
                          "retention deletion deferred for #{job_id}: #{inspect(reason)}"
                        )

                        acc
                    end

                  {:error, reason} ->
                    Logger.warning("retention cleanup deferred for #{job_id}: #{inspect(reason)}")

                    acc
                end
              else
                acc
              end

            {:error, reason} ->
              if missing_job?(job_id, reason) do
                case run_retention_cleanup(cleanup_job, job_id, nil) do
                  :ok ->
                    case delete_job(job_id) do
                      :ok ->
                        Map.update!(acc, :stale_job_ids, &[job_id | &1])

                      {:error, delete_reason} ->
                        Logger.warning(
                          "stale job deletion deferred for #{job_id}: #{inspect(delete_reason)}"
                        )

                        acc
                    end

                  {:error, cleanup_reason} ->
                    Logger.warning(
                      "stale job cleanup deferred for #{job_id}: #{inspect(cleanup_reason)}"
                    )

                    acc
                end
              else
                Logger.warning(
                  "retention could not classify job #{job_id}; cleanup deferred: #{inspect(reason)}"
                )

                acc
              end
          end
        end)

      deleted_jobs = Enum.reverse(result.deleted_jobs)
      stale_job_ids = Enum.reverse(result.stale_job_ids)

      {:ok,
       %{
         deleted_count: length(deleted_jobs),
         stale_count: length(stale_job_ids),
         deleted_jobs: deleted_jobs,
         stale_job_ids: stale_job_ids,
         deleted_recovery_eval_count: Map.get(eval_result, :deleted_recovery_eval_count, 0),
         stale_recovery_eval_count: Map.get(eval_result, :stale_recovery_eval_count, 0),
         deleted_recovery_evals: Map.get(eval_result, :deleted_recovery_evals, []),
         stale_recovery_evals: Map.get(eval_result, :stale_recovery_evals, []),
         stale_blob_ref_count: Map.get(blob_result, :stale_blob_ref_count, 0),
         stale_blob_refs: Map.get(blob_result, :stale_blob_refs, []),
         stale_service_instance_count: Map.get(service_result, :stale_service_instance_count, 0),
         stale_service_instances: Map.get(service_result, :stale_service_instances, []),
         stale_schedule_count: Map.get(schedule_result, :stale_schedule_count, 0),
         stale_schedules: Map.get(schedule_result, :stale_schedules, []),
         stale_trigger_event_key_count:
           Map.get(trigger_result, :stale_trigger_event_key_count, 0),
         stale_deployment_count: Map.get(deployment_result, :stale_deployment_count, 0),
         stale_deployments: Map.get(deployment_result, :stale_deployments, []),
         stale_deployment_version_count:
           Map.get(deployment_result, :stale_deployment_version_count, 0)
       }}
    end
  end

  defp run_retention_cleanup(cleanup_job, job_id, job) do
    result =
      cond do
        is_function(cleanup_job, 2) -> cleanup_job.(job_id, job)
        is_function(cleanup_job, 1) -> cleanup_job.(job_id)
      end

    case result do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_cleanup_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp refresh_job_blob_refs(job) do
    job
    |> BlobRef.collect()
    |> Enum.each(fn ref ->
      case register_blob_ref(ref) do
        {:ok, _blob} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "failed to refresh blob metadata #{ref["sha256"]} for job #{job["job_id"]}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  def acquire_lease(lease_name, owner_id, ttl_ms) do
    case command(["SET", key("lease", lease_name), owner_id, "PX", to_string(ttl_ms), "NX"]) do
      {:ok, "OK"} -> :ok
      {:ok, nil} -> {:error, :locked}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def renew_lease(lease_name, owner_id, ttl_ms) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("pexpire", KEYS[1], ARGV[2])
    else
      return 0
    end
    """

    case command(["EVAL", script, "1", key("lease", lease_name), owner_id, to_string(ttl_ms)]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def release_lease(lease_name, owner_id) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
    """

    case command(["EVAL", script, "1", key("lease", lease_name), owner_id]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def get_lease(lease_name) do
    case command(["GET", key("lease", lease_name)]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, owner_id} -> {:ok, owner_id}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def acquire_fenced_lease(lease_name, owner_id, ttl_ms) do
    lease_key = key("lease", lease_name)
    epoch_key = key("lease", lease_name, "epoch")

    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      local epoch = redis.call("incr", KEYS[2])
      redis.call("psetex", KEYS[1], ARGV[2], ARGV[1] .. "|" .. epoch)
      return {"ok", tostring(epoch)}
    else
      return {"locked", redis.call("get", KEYS[1])}
    end
    """

    case command(["EVAL", script, "2", lease_key, epoch_key, owner_id, to_string(ttl_ms)]) do
      {:ok, ["ok", epoch]} ->
        {:ok, lease_payload(owner_id, epoch, ttl_ms)}

      {:ok, ["locked", value]} ->
        {:error, {:locked, parse_fenced_lease(value)}}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def persist_service_instance(instance_id, service_map) do
    service =
      service_map
      |> stringify_map()
      |> Map.put("id", instance_id)
      |> Map.put_new("created_at", timestamp())
      |> Map.put("updated_at", timestamp())

    script = """
    local existing = redis.call("get", KEYS[1])

    if existing then
      local ok, decoded = pcall(cjson.decode, existing)

      if not ok or type(decoded) ~= "table" or tostring(decoded["id"]) ~= ARGV[1] then
        return redis.error_reply("invalid existing service instance " .. ARGV[1])
      end

      for index = 3, #ARGV, 3 do
        local old_value = decoded[ARGV[index]]

        if type(old_value) == "string" and old_value ~= "" then
          redis.call("srem", ARGV[index + 1] .. old_value, ARGV[1])
        end
      end
    end

    redis.call("set", KEYS[1], ARGV[2])
    redis.call("sadd", KEYS[2], ARGV[1])

    for index = 3, #ARGV, 3 do
      local new_value = ARGV[index + 2]

      if new_value ~= "" then
        redis.call("sadd", ARGV[index + 1] .. new_value, ARGV[1])
      end
    end

    return 1
    """

    args =
      [
        "EVAL",
        script,
        "2",
        key("service", "instance", instance_id),
        key("service", "instances"),
        instance_id,
        Jason.encode!(service)
      ] ++ service_index_script_args(service)

    case command(args) do
      {:ok, 1} ->
        with :ok <- wait_for_replicas(), do: {:ok, service}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, format_reason(other)}
    end
  end

  def fetch_service_instance(instance_id) do
    case command(["GET", key("service", "instance", instance_id)]) do
      {:ok, nil} ->
        {:error, "service instance #{instance_id} was not found"}

      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, service} when is_map(service) -> {:ok, service}
          {:ok, _invalid} -> {:error, :invalid_service_instance}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def list_service_instances(_opts \\ []) do
    case command(["SMEMBERS", key("service", "instances")]) do
      {:ok, ids} -> fetch_service_instances(Enum.sort(ids))
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def delete_service_instance(instance_id),
    do: delete_service_instance_if_matches(instance_id, [])

  def delete_service_instances(opts) when is_list(opts) do
    with {:ok, instance_ids} <- service_candidate_ids(opts) do
      Enum.reduce_while(instance_ids, :ok, fn instance_id, :ok ->
        continue_service_cleanup(delete_service_instance_if_matches(instance_id, opts))
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def renew_fenced_lease(lease_name, owner_id, epoch, ttl_ms) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("pexpire", KEYS[1], ARGV[2])
    else
      return 0
    end
    """

    case command([
           "EVAL",
           script,
           "1",
           key("lease", lease_name),
           fenced_lease_value(owner_id, epoch),
           to_string(ttl_ms)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def release_fenced_lease(lease_name, owner_id, epoch) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
    """

    case command([
           "EVAL",
           script,
           "1",
           key("lease", lease_name),
           fenced_lease_value(owner_id, epoch)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def release_ephemeral_fenced_lease(lease_name, owner_id, epoch) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      redis.call("del", KEYS[1])
      redis.call("del", KEYS[2])
      return 1
    else
      return 0
    end
    """

    case command([
           "EVAL",
           script,
           "2",
           key("lease", lease_name),
           key("lease", lease_name, "epoch"),
           fenced_lease_value(owner_id, epoch)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_bundle_archive(fingerprint, archive) do
    archive = Map.put(archive, "fingerprint", fingerprint)

    with {:ok, "OK"} <- command(["SET", key("bundle", fingerprint), Jason.encode!(archive)]),
         :ok <- expire_key(key("bundle", fingerprint), bundle_archive_ttl_seconds()),
         :ok <- wait_for_replicas() do
      {:ok, archive}
    end
  end

  def fetch_bundle_archive(fingerprint) do
    case command(["GET", key("bundle", fingerprint)]) do
      {:ok, nil} -> {:error, "bundle archive #{fingerprint} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def refresh_bundle_archive(fingerprint) when is_binary(fingerprint) and fingerprint != "" do
    redis_key = key("bundle", fingerprint)

    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      return 0
    end

    redis.call("persist", KEYS[1])
    return 1
    """

    case command(["EVAL", script, "1", redis_key]) do
      {:ok, 1} -> wait_for_replicas()
      {:ok, 0} -> {:error, :not_found}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def refresh_bundle_archive(_fingerprint), do: {:error, :invalid_fingerprint}

  def expire_unreferenced_bundle_archives(referenced_fingerprints) do
    referenced = MapSet.new(referenced_fingerprints)
    ttl_seconds = bundle_archive_ttl_seconds()

    if is_integer(ttl_seconds) and ttl_seconds > 0 do
      with {:ok, archive_keys} <- scan_keys(key("bundle", "*")),
           archive_refs <-
             archive_keys
             |> Enum.flat_map(&bundle_archive_ref_from_key/1)
             |> Enum.reject(fn {fingerprint, _redis_key} ->
               MapSet.member?(referenced, fingerprint)
             end),
           {:ok, transitioned} <- expire_persistent_bundle_archives(archive_refs, ttl_seconds),
           :ok <- maybe_wait_for_deleted_keys(transitioned) do
        {:ok, transitioned}
      else
        {:error, reason} -> {:error, format_reason(reason)}
        other -> {:error, format_reason(other)}
      end
    else
      {:ok, 0}
    end
  end

  def referenced_bundle_fingerprints do
    with {:ok, redis_job_keys} <- scan_keys(key("job", "*")),
         job_ids <- redis_job_keys |> Enum.flat_map(&root_job_id_from_key/1) |> Enum.uniq(),
         {:ok, schedule_ids} <- raw_schedule_index_ids(),
         {:ok, version_keys} <-
           scan_keys(key("deployment", "key", "*", "version", "*")),
         reference_keys <-
           Enum.map(job_ids, &key("job", &1)) ++
             Enum.map(schedule_ids, &key("schedule", &1)) ++ version_keys,
         {:ok, records} <- fetch_bundle_reference_records(reference_keys) do
      fingerprints =
        records
        |> Enum.flat_map(&bundle_fingerprints/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, fingerprints}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def register_blob_ref(ref) when is_map(ref) do
    ref = stringify_map(ref)
    sha256 = Map.get(ref, "sha256")

    with true <- is_binary(sha256) and sha256 != "",
         existing <- existing_blob_ref(sha256),
         blob <- merge_blob_ref(existing, ref),
         {:ok, "OK"} <- command(["SET", key("blob", sha256), Jason.encode!(blob)]),
         {:ok, _count} <- command(["SADD", key("blobs"), sha256]),
         :ok <- expire_key(key("blob", sha256), blob_ref_ttl_seconds()),
         :ok <- wait_for_replicas() do
      {:ok, blob}
    else
      false -> {:error, "blob ref requires sha256"}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def fetch_blob_ref(sha256) when is_binary(sha256) do
    case command(["GET", key("blob", sha256)]) do
      {:ok, nil} -> {:error, "blob #{sha256} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_blob_refs do
    with {:ok, %{active_blob_refs: sha_values}} <- sweep_blob_ref_index() do
      refs =
        sha_values
        |> Enum.sort()
        |> Enum.map(fn sha256 ->
          case fetch_blob_ref(sha256) do
            {:ok, ref} -> ref
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, refs}
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp sweep_blob_ref_index do
    with {:ok, sha_values} <- command(["SMEMBERS", key("blobs")]),
         {:ok, existence} <- blob_ref_existence(sha_values),
         :ok <- expect_no_redis_errors(existence),
         {active, stale} <- partition_blob_refs(sha_values, existence),
         :ok <- remove_stale_blob_ref_indexes(stale) do
      stale = Enum.sort(stale)

      {:ok,
       %{
         active_blob_refs: Enum.sort(active),
         stale_blob_ref_count: length(stale),
         stale_blob_refs: stale
       }}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp blob_ref_existence([]), do: {:ok, []}

  defp blob_ref_existence(sha_values) do
    pipeline(Enum.map(sha_values, &["EXISTS", key("blob", &1)]))
  end

  defp partition_blob_refs(sha_values, existence) do
    sha_values
    |> Enum.zip(existence)
    |> Enum.reduce({[], []}, fn
      {sha256, 1}, {active, stale} -> {[sha256 | active], stale}
      {sha256, 0}, {active, stale} -> {active, [sha256 | stale]}
    end)
  end

  defp remove_stale_blob_ref_indexes([]), do: :ok

  defp remove_stale_blob_ref_indexes(stale) do
    case command(["SREM", key("blobs") | stale]) do
      {:ok, _removed} -> :ok
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_node_state(node_name, attrs) do
    state =
      attrs
      |> stringify_map()
      |> Map.put("node", node_name)
      |> Map.put("updated_at", timestamp())

    with {:ok, results} <-
           transaction([
             ["SET", key("node", node_name, "state"), Jason.encode!(state)],
             ["SADD", key("nodes"), node_name]
           ]),
         :ok <- expect_no_redis_errors(results),
         :ok <- wait_for_replicas() do
      {:ok, state}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def fetch_node_state(node_name) do
    case command(["GET", key("node", node_name, "state")]) do
      {:ok, nil} ->
        {:error, "node #{node_name} state was not found"}

      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, state} when is_map(state) -> {:ok, state}
          {:ok, _invalid} -> {:error, :invalid_node_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def list_node_states do
    case command(["SMEMBERS", key("nodes")]) do
      {:ok, node_names} ->
        node_names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, [], false}, &collect_node_state/2)
        |> finish_node_state_listing()

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def persist_recovery_eval(eval_id, eval_map) do
    eval =
      eval_map
      |> stringify_map()
      |> compact_recovery_eval()
      |> Map.put("eval_id", eval_id)
      |> Map.put_new("created_at", timestamp())
      |> Map.put("updated_at", timestamp())

    with {:ok, results} <-
           transaction(
             [
               ["SET", key("recovery", "eval", eval_id), Jason.encode!(eval)],
               ["SADD", key("recovery", "evals"), eval_id]
               | recovery_eval_status_index_commands(eval_id, Map.get(eval, "status"))
             ] ++ recovery_eval_retention_commands(eval_id, Map.get(eval, "status"))
           ),
         :ok <- expect_no_redis_errors(results),
         :ok <- wait_for_replicas() do
      {:ok, eval}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def fetch_recovery_eval(eval_id) do
    case command(["GET", key("recovery", "eval", eval_id)]) do
      {:ok, nil} -> {:error, "recovery eval #{eval_id} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_recovery_evals(statuses \\ :all)

  def list_recovery_evals(:all) do
    case command(["SMEMBERS", key("recovery", "evals")]) do
      {:ok, eval_ids} ->
        fetch_recovery_evals(eval_ids)

      {:error, reason} ->
        {:error, format_reason(reason)}
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
      |> Map.merge(stringify_map(updates))
      |> Map.put("eval_id", eval_id)
      |> Map.put("updated_at", timestamp())

    persist_recovery_eval(eval_id, eval)
  end

  def fetch_resource_limits do
    case command(["GET", key("resource", "limits")]) do
      {:ok, nil} -> {:error, "resource limits were not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_resource_limits(limits) when is_map(limits) do
    limits = stringify_map(limits)

    with {:ok, "OK"} <- command(["SET", key("resource", "limits"), Jason.encode!(limits)]),
         :ok <- wait_for_replicas() do
      {:ok, limits}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp compact_legacy_job_ids(job_ids) do
    Enum.map(job_ids, fn job_id ->
      if JobId.legacy?(job_id), do: compact_legacy_job_id(job_id), else: job_id
    end)
  end

  defp compact_legacy_job_id(job_id) do
    with {:ok, compact_id} <- JobId.compact_legacy(job_id),
         {:ok, final_id} <- available_compact_id(compact_id, job_id),
         :ok <- rename_job_keys(job_id, final_id) do
      final_id
    else
      _ -> job_id
    end
  end

  defp available_compact_id(compact_id, job_id) do
    case command(["EXISTS", key("job", compact_id)]) do
      {:ok, 0} -> {:ok, compact_id}
      {:ok, 1} when compact_id == job_id -> {:ok, compact_id}
      {:ok, 1} -> {:ok, "#{compact_id}-#{System.unique_integer([:positive])}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_job_keys(job_id, compact_id) do
    with {:ok, job} <- fetch_job(job_id),
         {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]),
         {:ok, _job} <- persist_job(compact_id, Map.put(job, "job_id", compact_id)),
         :ok <- copy_key(key("job", job_id, "events"), key("job", compact_id, "events")),
         :ok <- copy_key(key("job", job_id, "agents"), key("job", compact_id, "agents")),
         :ok <- copy_agent_keys(job_id, compact_id, agent_ids) do
      delete_legacy_job_keys(job_id, agent_ids)
    end
  end

  defp copy_agent_keys(job_id, compact_id, agent_ids) do
    Enum.reduce_while(agent_ids, :ok, fn agent_id, :ok ->
      case copy_key(
             key("job", job_id, "agent", agent_id),
             key("job", compact_id, "agent", agent_id)
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_key(source, target) do
    case command(["DUMP", source]) do
      {:ok, nil} ->
        :ok

      {:ok, serialized} ->
        case command(["RESTORE", target, "0", serialized, "REPLACE"]) do
          {:ok, "OK"} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_legacy_job_keys(job_id, agent_ids) do
    keys =
      [
        key("job", job_id),
        key("job", job_id, "summary"),
        key("job", job_id, "events"),
        key("job", job_id, "agents")
      ] ++ Enum.map(agent_ids, &key("job", job_id, "agent", &1))

    _ = command(["DEL" | keys])
    _ = command(["SREM", key(@jobs_set), job_id])
    :ok
  end

  defp fetch_jobs([]), do: {:ok, []}

  defp fetch_jobs(job_ids) do
    keys = Enum.map(job_ids, &key("job", &1))

    case command(["MGET" | keys]) do
      {:ok, encoded_jobs} -> {:ok, decode_json_items(encoded_jobs)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp fetch_job_summaries([]), do: {:ok, []}

  defp fetch_job_summaries(job_ids) do
    keys = Enum.map(job_ids, &key("job", &1, "summary"))

    case command(["MGET" | keys]) do
      {:ok, encoded_summaries} ->
        summaries =
          job_ids
          |> Enum.zip(encoded_summaries)
          |> Enum.map(fn
            {_job_id, encoded} when is_binary(encoded) ->
              case Jason.decode(encoded) do
                {:ok, summary} when is_map(summary) -> summary
                _ -> nil
              end

            {job_id, _missing} ->
              fetch_and_store_job_summary(job_id)
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, summaries}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp fetch_and_store_job_summary(job_id) do
    case fetch_job(job_id) do
      {:ok, job} when is_map(job) ->
        summary = job_summary(job_id, job)
        _ = store_job_summary(job_id, summary, Map.get(summary, "status"))
        summary

      _ ->
        nil
    end
  end

  defp store_job_summary(job_id, summary, status) do
    with {:ok, "OK"} <- command(["SET", key("job", job_id, "summary"), Jason.encode!(summary)]) do
      if terminal_status?(status) do
        expire_key(key("job", job_id, "summary"), terminal_job_ttl_seconds())
      else
        persist_key(key("job", job_id, "summary"))
      end
    end
  end

  defp job_summary(job_id, job) do
    %{
      "job_id" => field(job, "job_id") || job_id,
      "graph_id" => field(job, "graph_id"),
      "job_name" => field(job, "job_name"),
      "status" => field(job, "status"),
      "job_type" => field(job, "job_type"),
      "submitted_at" => field(job, "submitted_at"),
      "updated_at" => field(job, "updated_at"),
      "placement_policy" => field(job, "placement_policy"),
      "scheduler" => field(job, "scheduler"),
      "requested_recovery_policy" => field(job, "requested_recovery_policy"),
      "recovery_policy" => field(job, "recovery_policy"),
      "reliability" => field(job, "reliability"),
      "restart_policy" => field(job, "restart_policy"),
      "reschedule_policy" => field(job, "reschedule_policy"),
      "policy_state" => field(job, "policy_state"),
      "recovery_status" => field(job, "recovery_status"),
      "recovery_requires_review" => field(job, "recovery_requires_review", false),
      "recovery_reason" => field(job, "recovery_reason"),
      "recovery_hint" => recovery_hint(job),
      "executor_count" => field(job, "executor_count", 0),
      "active_executors" => field(job, "active_executors", 0),
      "nodes" => field(job, "nodes", []),
      "sandbox_names" => field(job, "sandbox_names", []),
      "last_event" => field(job, "last_event")
    }
  end

  defp recovery_hint(job) do
    if field(job, "status") == "failed" and runner_interruption_result?(field(job, "result")) do
      "runner_interruption"
    end
  end

  defp runner_interruption_result?(result) when is_map(result) do
    field(result, "agent_id") == "job_runner" and
      field(result, "error") == "job coordinator exited before terminal state"
  end

  defp runner_interruption_result?(_result), do: false

  defp field(map, name, default \\ nil) when is_map(map) do
    Map.get(map, name, Map.get(map, String.to_atom(name), default))
  end

  defp fetch_indexed_schedules(schedule_ids) do
    schedule_ids
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn schedule_id, {:ok, schedules} ->
      case fetch_schedule(schedule_id) do
        {:ok, schedule} ->
          {:cont, {:ok, [schedule | schedules]}}

        {:error, reason} ->
          cond do
            missing_schedule?(schedule_id, reason) ->
              case purge_missing_schedule(schedule_id) do
                {:ok, _result} -> {:cont, {:ok, schedules}}
                {:error, cleanup_reason} -> {:halt, {:error, cleanup_reason}}
              end

            corrupt_schedule?(reason) ->
              Logger.debug("ignoring unreadable schedule #{schedule_id}: #{inspect(reason)}")
              {:cont, {:ok, schedules}}

            true ->
              {:halt, {:error, format_reason(reason)}}
          end
      end
    end)
    |> case do
      {:ok, schedules} -> {:ok, Enum.reverse(schedules)}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_indexed_deployments(deployment_ids) do
    deployment_ids
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn deployment_id, {:ok, deployments} ->
      case fetch_deployment(deployment_id) do
        {:ok, deployment} ->
          {:cont, {:ok, [deployment | deployments]}}

        {:error, reason} ->
          cond do
            missing_deployment?(deployment_id, reason) ->
              case purge_missing_deployment(deployment_id) do
                :ok -> {:cont, {:ok, deployments}}
                {:error, cleanup_reason} -> {:halt, {:error, cleanup_reason}}
              end

            corrupt_deployment?(reason) ->
              Logger.debug("ignoring unreadable deployment #{deployment_id}: #{inspect(reason)}")
              {:cont, {:ok, deployments}}

            true ->
              {:halt, {:error, format_reason(reason)}}
          end
      end
    end)
    |> case do
      {:ok, deployments} -> {:ok, Enum.reverse(deployments)}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_indexed_deployment_versions(deployment_key, versions) do
    versions
    |> Enum.sort_by(&version_sort_value/1)
    |> Enum.reduce_while({:ok, []}, fn version, {:ok, records} ->
      case fetch_job_version(deployment_key, version) do
        {:ok, record} ->
          {:cont, {:ok, [record | records]}}

        {:error, reason} ->
          cond do
            missing_deployment_version?(deployment_key, version, reason) ->
              case remove_missing_deployment_version(deployment_key, version) do
                :ok -> {:cont, {:ok, records}}
                {:error, cleanup_reason} -> {:halt, {:error, cleanup_reason}}
              end

            corrupt_deployment_version?(reason) ->
              Logger.debug(
                "ignoring unreadable deployment #{deployment_key} version #{version}: #{inspect(reason)}"
              )

              {:cont, {:ok, records}}

            true ->
              {:halt, {:error, format_reason(reason)}}
          end
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp remove_stale_deployment_pointer(current_key, deployment_key, deployment_id) do
    script = """
    if redis.call("get", KEYS[2]) ~= ARGV[1] then
      return 0
    end

    local existing = redis.call("get", KEYS[1])

    if existing then
      local ok, decoded = pcall(cjson.decode, existing)

      if ok and type(decoded) == "table" and decoded["deployment_key"] == ARGV[2] then
        return 0
      end
    end

    redis.call("del", KEYS[2])
    redis.call("srem", KEYS[3], ARGV[1])
    return 1
    """

    deployments_key = key("deployment", "key", deployment_key, "deployments")

    case command([
           "EVAL",
           script,
           "3",
           key("deployment", deployment_id),
           current_key,
           deployments_key,
           deployment_id,
           deployment_key
         ]) do
      {:ok, _removed} -> :ok
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp purge_missing_deployment(deployment_id) do
    with {:ok, current_keys} <- scan_keys(key("deployment", "key", "*", "current")),
         {:ok, deployment_set_keys} <-
           scan_keys(key("deployment", "key", "*", "deployments")),
         {:ok, _result} <-
           purge_missing_deployment(deployment_id, current_keys, deployment_set_keys) do
      :ok
    end
  end

  defp purge_missing_deployment(deployment_id, current_keys, deployment_set_keys) do
    script = """
    if redis.call("exists", KEYS[1]) ~= 0 then
      return 0
    end

    redis.call("srem", KEYS[2], ARGV[1])
    local current_count = tonumber(ARGV[2])

    for index = 3, 2 + current_count do
      if redis.call("get", KEYS[index]) == ARGV[1] then
        redis.call("del", KEYS[index])
      end
    end

    for index = 3 + current_count, #KEYS do
      redis.call("srem", KEYS[index], ARGV[1])
    end

    return 1
    """

    keys =
      [key("deployment", deployment_id), key(@deployments_set)] ++
        current_keys ++ deployment_set_keys

    case command([
           "EVAL",
           script,
           to_string(length(keys))
           | keys ++ [deployment_id, to_string(length(current_keys))]
         ]) do
      {:ok, result} when result in [0, 1] ->
        with :ok <- maybe_wait_for_deleted_keys(result), do: {:ok, result}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, format_reason(other)}
    end
  end

  defp remove_missing_deployment_version(deployment_key, version) do
    version = to_string(version)
    version_key = key("deployment", "key", deployment_key, "version", version)
    versions_key = key("deployment", "key", deployment_key, "versions")

    case remove_missing_deployment_version(version_key, versions_key, version) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp remove_missing_deployment_version(version_key, versions_key, version) do
    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      redis.call("srem", KEYS[2], ARGV[1])
      return 1
    end

    return 0
    """

    case command([
           "EVAL",
           script,
           "2",
           version_key,
           versions_key,
           version
         ]) do
      {:ok, result} when result in [0, 1] ->
        with :ok <- maybe_wait_for_deleted_keys(result), do: {:ok, result}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, format_reason(other)}
    end
  end

  defp fetch_bundle_reference_records([]), do: {:ok, []}

  defp fetch_bundle_reference_records(redis_keys) do
    redis_keys
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, records} ->
      case fetch_bundle_reference_chunk(chunk) do
        {:ok, chunk_records} -> {:cont, {:ok, [chunk_records | records]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_bundle_reference_chunk(redis_keys) do
    case command(["MGET" | redis_keys]) do
      {:ok, encoded_records} ->
        redis_keys
        |> Enum.zip(encoded_records)
        |> Enum.reduce_while({:ok, []}, fn
          {_redis_key, nil}, {:ok, records} ->
            {:cont, {:ok, records}}

          {redis_key, encoded}, {:ok, records} ->
            case Jason.decode(encoded) do
              {:ok, record} when is_map(record) ->
                {:cont, {:ok, [record | records]}}

              {:ok, _invalid} ->
                {:halt, {:error, {:invalid_bundle_reference_record, redis_key}}}

              {:error, reason} ->
                {:halt, {:error, {:unreadable_bundle_reference_record, redis_key, reason}}}
            end
        end)
        |> reverse_record_result()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reverse_record_result({:ok, records}), do: {:ok, Enum.reverse(records)}
  defp reverse_record_result({:error, _reason} = error), do: error

  defp bundle_fingerprints(record) do
    [
      get_in(record, ["manifest_ref", "bundle_fingerprint"]),
      get_in(record, ["bundle_ref", "bundle_fingerprint"]),
      Map.get(record, "bundle_fingerprint")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp expire_persistent_bundle_archives(archive_refs, ttl_seconds) do
    Enum.reduce_while(archive_refs, {:ok, 0}, fn {_fingerprint, redis_key}, {:ok, count} ->
      case command(["TTL", redis_key]) do
        {:ok, -1} ->
          case command(["EXPIRE", redis_key, to_string(ttl_seconds)]) do
            {:ok, 1} -> {:cont, {:ok, count + 1}}
            {:ok, 0} -> {:cont, {:ok, count}}
            {:error, reason} -> {:halt, {:error, reason}}
            other -> {:halt, {:error, other}}
          end

        {:ok, ttl} when is_integer(ttl) ->
          {:cont, {:ok, count}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, other}}
      end
    end)
  end

  defp collect_node_state(node_name, {:ok, states, removed_stale?}) do
    case fetch_node_state(node_name) do
      {:ok, state} ->
        {:cont, {:ok, [state | states], removed_stale?}}

      {:error, reason} ->
        cond do
          missing_node_state?(node_name, reason) ->
            case command(["SREM", key("nodes"), node_name]) do
              {:ok, removed} when is_integer(removed) ->
                {:cont, {:ok, states, removed_stale? or removed > 0}}

              {:error, cleanup_reason} ->
                {:halt, {:error, format_reason(cleanup_reason)}}

              other ->
                {:halt, {:error, format_reason(other)}}
            end

          corrupt_node_state?(reason) ->
            Logger.debug("ignoring unreadable node state #{node_name}: #{inspect(reason)}")
            {:cont, {:ok, states, removed_stale?}}

          true ->
            {:halt, {:error, format_reason(reason)}}
        end
    end
  end

  defp finish_node_state_listing({:ok, states, false}), do: {:ok, Enum.reverse(states)}

  defp finish_node_state_listing({:ok, states, true}) do
    with :ok <- wait_for_replicas(), do: {:ok, Enum.reverse(states)}
  end

  defp finish_node_state_listing({:error, _reason} = error), do: error

  defp fetch_service_instances([]), do: {:ok, []}

  defp fetch_service_instances(instance_ids) do
    keys = Enum.map(instance_ids, &key("service", "instance", &1))

    case command(["MGET" | keys]) do
      {:ok, encoded_services} ->
        instance_ids
        |> Enum.zip(encoded_services)
        |> Enum.reduce_while({:ok, []}, fn
          {instance_id, nil}, {:ok, services} ->
            case purge_missing_service_instance(instance_id) do
              {:ok, _result} -> {:cont, {:ok, services}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {instance_id, encoded}, {:ok, services} ->
            case Jason.decode(encoded) do
              {:ok, service} when is_map(service) ->
                {:cont, {:ok, [service | services]}}

              {:error, reason} ->
                Logger.debug(
                  "ignoring unreadable service instance #{instance_id}: #{inspect(reason)}"
                )

                {:cont, {:ok, services}}

              {:ok, _invalid} ->
                Logger.debug("ignoring invalid service instance #{instance_id}")
                {:cont, {:ok, services}}
            end
        end)
        |> case do
          {:ok, services} -> {:ok, Enum.reverse(services)}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp service_candidate_ids(opts) do
    selector_keys = service_selector_index_keys(opts)

    cond do
      opts == [] ->
        command(["SMEMBERS", key("service", "instances")])

      selector_keys == [] ->
        {:error, :invalid_service_filter}

      length(selector_keys) == 1 ->
        command(["SMEMBERS", hd(selector_keys)])

      true ->
        command(["SINTER" | selector_keys])
    end
  end

  defp service_selector_index_keys(opts) do
    opts
    |> Enum.flat_map(fn {option, value} ->
      case List.keyfind(@service_index_fields, option, 0) do
        {_option, index} -> [key("service", index, to_string(value))]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  defp continue_service_cleanup(:ok), do: {:cont, :ok}
  defp continue_service_cleanup({:error, reason}), do: {:halt, {:error, reason}}

  defp delete_service_instance_if_matches(instance_id, opts) do
    with {:ok, index_keys} <- service_secondary_index_keys() do
      script = """
      local encoded = redis.call("get", KEYS[1])
      local should_delete = true
      local selector_count = tonumber(ARGV[2])
      local service = nil

      if encoded then
        local ok, decoded = pcall(cjson.decode, encoded)

        if ok and type(decoded) == "table" then
          service = decoded

          for index = 3, 2 + selector_count * 3, 3 do
            local value = service[ARGV[index]]

            if type(value) ~= "string" or value ~= ARGV[index + 1] then
              should_delete = false
            end
          end
        end
      end

      if should_delete then
        redis.call("del", KEYS[1])
        redis.call("srem", KEYS[2], ARGV[1])

        for index = 3, #KEYS do
          redis.call("srem", KEYS[index], ARGV[1])
        end

        if service then
          for index = 3 + selector_count * 3, #ARGV, 2 do
            local value = service[ARGV[index]]

            if type(value) == "string" and value ~= "" then
              redis.call("srem", ARGV[index + 1] .. value, ARGV[1])
            end
          end
        end

        return 1
      end

      for index = 3, 2 + selector_count * 3, 3 do
        redis.call("srem", ARGV[index + 2], ARGV[1])
      end

      return 0
      """

      keys = [key("service", "instance", instance_id), key("service", "instances") | index_keys]
      selector_args = service_selector_script_args(opts)

      args =
        [instance_id, to_string(div(length(selector_args), 3))] ++
          selector_args ++ service_index_prefix_script_args()

      case command(["EVAL", script, to_string(length(keys)) | keys ++ args]) do
        {:ok, result} when result in [0, 1] -> maybe_wait_for_deleted_keys(result)
        {:error, reason} -> {:error, format_reason(reason)}
        other -> {:error, format_reason(other)}
      end
    end
  end

  defp purge_missing_service_instance(instance_id) do
    with {:ok, index_keys} <- service_secondary_index_keys() do
      purge_missing_service_instance(instance_id, index_keys)
    end
  end

  defp purge_missing_service_instance(instance_id, index_keys) do
    script = """
    if redis.call("exists", KEYS[1]) ~= 0 then
      return 0
    end

    redis.call("srem", KEYS[2], ARGV[1])

    for index = 3, #KEYS do
      redis.call("srem", KEYS[index], ARGV[1])
    end

    return 1
    """

    keys = [key("service", "instance", instance_id), key("service", "instances") | index_keys]

    case command(["EVAL", script, to_string(length(keys)) | keys ++ [instance_id]]) do
      {:ok, result} when result in [0, 1] ->
        with :ok <- maybe_wait_for_deleted_keys(result), do: {:ok, result}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, format_reason(other)}
    end
  end

  defp service_secondary_index_keys do
    @service_index_fields
    |> Enum.reduce_while({:ok, []}, fn {_option, index}, {:ok, keys} ->
      case scan_keys(key("service", index, "*")) do
        {:ok, found} -> {:cont, {:ok, found ++ keys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.uniq(keys)}
      {:error, _reason} = error -> error
    end
  end

  defp sweep_service_instance_index do
    with {:ok, secondary_keys} <- service_secondary_index_keys(),
         index_keys <- [key("service", "instances") | secondary_keys],
         {:ok, indexed_ids} <- service_index_ids(index_keys),
         {:ok, existence} <- service_instance_existence(indexed_ids),
         :ok <- expect_no_redis_errors(existence),
         stale <- stale_service_instance_ids(indexed_ids, existence),
         {:ok, removed} <- purge_stale_service_instances(stale, secondary_keys) do
      removed = Enum.sort(removed)

      {:ok,
       %{
         stale_service_instance_count: length(removed),
         stale_service_instances: removed
       }}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp sweep_schedule_index do
    with {:ok, schedule_ids} <- raw_schedule_index_ids(),
         {:ok, existence} <- schedule_existence(schedule_ids),
         :ok <- expect_no_redis_errors(existence),
         stale <- stale_schedule_ids(schedule_ids, existence),
         {:ok, removed} <- purge_stale_schedules(stale) do
      removed = Enum.sort(removed)
      {:ok, %{stale_schedule_count: length(removed), stale_schedules: removed}}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp raw_schedule_index_ids do
    with {:ok, index_results} <-
           pipeline([
             ["SMEMBERS", key(@schedules_set)],
             ["ZRANGE", key(@schedule_due_zset), "0", "-1"]
           ]),
         :ok <- expect_no_redis_errors(index_results) do
      {:ok, index_results |> Enum.flat_map(& &1) |> Enum.uniq() |> Enum.sort()}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp schedule_existence([]), do: {:ok, []}

  defp schedule_existence(schedule_ids) do
    pipeline(Enum.map(schedule_ids, &["EXISTS", key("schedule", &1)]))
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

  defp purge_missing_schedule(schedule_id) do
    with {:ok, lease_keys} <- scan_keys(key("lease", "schedule:#{schedule_id}:*")) do
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
          key("schedule", schedule_id),
          key(@schedules_set),
          key(@schedule_due_zset)
          | lease_keys
        ]

      case command(["EVAL", script, to_string(length(keys)) | keys ++ [schedule_id]]) do
        {:ok, result} when result in [0, 1] ->
          with :ok <- maybe_wait_for_deleted_keys(result), do: {:ok, result}

        {:error, reason} ->
          {:error, format_reason(reason)}

        other ->
          {:error, format_reason(other)}
      end
    end
  end

  defp sweep_deployment_indexes do
    with {:ok, current_keys} <- scan_keys(key("deployment", "key", "*", "current")),
         {:ok, deployment_set_keys} <-
           scan_keys(key("deployment", "key", "*", "deployments")),
         {:ok, deployment_ids} <-
           deployment_index_ids(current_keys, deployment_set_keys),
         {:ok, existence} <- deployment_existence(deployment_ids),
         :ok <- expect_no_redis_errors(existence),
         stale_ids <- stale_deployment_ids(deployment_ids, existence),
         {:ok, removed_ids} <-
           purge_stale_deployments(stale_ids, current_keys, deployment_set_keys),
         {:ok, version_set_keys} <-
           scan_keys(key("deployment", "key", "*", "versions")),
         {:ok, removed_versions} <- sweep_missing_deployment_versions(version_set_keys) do
      removed_ids = Enum.sort(removed_ids)

      {:ok,
       %{
         stale_deployment_count: length(removed_ids),
         stale_deployments: removed_ids,
         stale_deployment_version_count: removed_versions
       }}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp deployment_index_ids(current_keys, deployment_set_keys) do
    set_keys = [key(@deployments_set) | deployment_set_keys]

    with {:ok, set_results} <- pipeline(Enum.map(set_keys, &["SMEMBERS", &1])),
         :ok <- expect_no_redis_errors(set_results),
         {:ok, current_ids} <- deployment_current_ids(current_keys) do
      ids = set_results |> Enum.flat_map(& &1) |> Kernel.++(current_ids)
      {:ok, ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp deployment_current_ids([]), do: {:ok, []}

  defp deployment_current_ids(current_keys) do
    case command(["MGET" | current_keys]) do
      {:ok, deployment_ids} -> {:ok, Enum.reject(deployment_ids, &is_nil/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deployment_existence([]), do: {:ok, []}

  defp deployment_existence(deployment_ids) do
    pipeline(Enum.map(deployment_ids, &["EXISTS", key("deployment", &1)]))
  end

  defp stale_deployment_ids(deployment_ids, existence) do
    deployment_ids
    |> Enum.zip(existence)
    |> Enum.flat_map(fn
      {deployment_id, 0} -> [deployment_id]
      {_deployment_id, 1} -> []
    end)
  end

  defp purge_stale_deployments(deployment_ids, current_keys, deployment_set_keys) do
    Enum.reduce_while(deployment_ids, {:ok, []}, fn deployment_id, {:ok, removed} ->
      case purge_missing_deployment(deployment_id, current_keys, deployment_set_keys) do
        {:ok, 1} -> {:cont, {:ok, [deployment_id | removed]}}
        {:ok, 0} -> {:cont, {:ok, removed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      {:error, _reason} = error -> error
    end
  end

  defp sweep_missing_deployment_versions(version_set_keys) do
    Enum.reduce_while(version_set_keys, {:ok, 0}, fn versions_key, {:ok, removed} ->
      case command(["SMEMBERS", versions_key]) do
        {:ok, versions} ->
          case sweep_missing_deployment_versions(versions_key, versions) do
            {:ok, count} -> {:cont, {:ok, removed + count}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sweep_missing_deployment_versions(versions_key, versions) do
    Enum.reduce_while(versions, {:ok, 0}, fn version, {:ok, removed} ->
      version_key =
        String.replace_suffix(versions_key, ":versions", ":version:#{version}")

      case command(["EXISTS", version_key]) do
        {:ok, 1} ->
          {:cont, {:ok, removed}}

        {:ok, 0} ->
          case remove_missing_deployment_version(version_key, versions_key, version) do
            {:ok, result} -> {:cont, {:ok, removed + result}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, other}}
      end
    end)
  end

  defp sweep_legacy_trigger_event_keys do
    with {:ok, keys} <- scan_keys(key("trigger", "event", "*")),
         {:ok, deleted} <- delete_redis_keys(keys),
         :ok <- maybe_wait_for_deleted_keys(deleted) do
      {:ok, %{stale_trigger_event_key_count: deleted}}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  defp delete_redis_keys([]), do: {:ok, 0}
  defp delete_redis_keys(keys), do: command(["DEL" | keys])

  defp maybe_wait_for_deleted_keys(0), do: :ok
  defp maybe_wait_for_deleted_keys(_deleted), do: wait_for_replicas()

  defp service_index_ids(index_keys) do
    case pipeline(Enum.map(index_keys, &["SMEMBERS", &1])) do
      {:ok, results} ->
        with :ok <- expect_no_redis_errors(results) do
          {:ok, results |> Enum.flat_map(& &1) |> Enum.uniq() |> Enum.sort()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp service_instance_existence([]), do: {:ok, []}

  defp service_instance_existence(instance_ids) do
    pipeline(Enum.map(instance_ids, &["EXISTS", key("service", "instance", &1)]))
  end

  defp stale_service_instance_ids(instance_ids, existence) do
    instance_ids
    |> Enum.zip(existence)
    |> Enum.flat_map(fn
      {instance_id, 0} -> [instance_id]
      {_instance_id, 1} -> []
    end)
  end

  defp purge_stale_service_instances(instance_ids, index_keys) do
    Enum.reduce_while(instance_ids, {:ok, []}, fn instance_id, {:ok, removed} ->
      case purge_missing_service_instance(instance_id, index_keys) do
        {:ok, 1} -> {:cont, {:ok, [instance_id | removed]}}
        {:ok, 0} -> {:cont, {:ok, removed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      {:error, _reason} = error -> error
    end
  end

  defp service_index_script_args(service) do
    Enum.flat_map(@service_index_fields, fn {option, index} ->
      field = Atom.to_string(option)
      value = Map.get(service, field)
      value = if is_binary(value), do: value, else: ""
      [field, key("service", index, ""), value]
    end)
  end

  defp service_selector_script_args(opts) do
    Enum.flat_map(opts, fn {option, value} ->
      case List.keyfind(@service_index_fields, option, 0) do
        {_option, index} ->
          [Atom.to_string(option), to_string(value), key("service", index, to_string(value))]

        nil ->
          []
      end
    end)
  end

  defp service_index_prefix_script_args do
    Enum.flat_map(@service_index_fields, fn {option, index} ->
      [Atom.to_string(option), key("service", index, "")]
    end)
  end

  defp existing_blob_ref(sha256) do
    case fetch_blob_ref(sha256) do
      {:ok, existing} when is_map(existing) -> existing
      _ -> %{}
    end
  end

  defp merge_blob_ref(existing, incoming) do
    now = timestamp()

    existing
    |> Map.merge(Map.drop(incoming, ["locations"]))
    |> Map.put("sha256", incoming["sha256"])
    |> Map.put_new("created_at", now)
    |> Map.put("updated_at", now)
    |> Map.put("locations", merge_blob_locations(existing["locations"], incoming["locations"]))
  end

  defp merge_blob_locations(existing, incoming) do
    (List.wrap(existing) ++ List.wrap(incoming))
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_map/1)
    |> Enum.filter(&valid_blob_location?/1)
    |> Enum.reverse()
    |> Enum.uniq_by(fn location ->
      {
        Map.get(location, "node"),
        Map.get(location, "storage") || Map.get(location, "type"),
        Map.get(location, "path"),
        Map.get(location, "url")
      }
    end)
    |> Enum.reverse()
  end

  defp valid_blob_location?(location) do
    url = Map.get(location, "url")
    storage = Map.get(location, "storage") || Map.get(location, "type")
    path = Map.get(location, "path")

    (is_binary(url) and url != "") or
      (storage in ["shared_fs", "shared_fs_cas"] and is_binary(path) and path != "")
  end

  defp schedule_due_commands(
         %{"enabled" => true, "status" => status, "next_run_at" => next_run_at} = schedule
       )
       when status in ["active", "running"] and is_binary(next_run_at) do
    [
      [
        "ZADD",
        key(@schedule_due_zset),
        to_string(schedule_score(next_run_at)),
        schedule["schedule_id"]
      ]
    ]
  end

  defp schedule_due_commands(_schedule), do: []

  defp schedule_due_score(%{"enabled" => true, "status" => status, "next_run_at" => next_run_at})
       when status in ["active", "running"] and is_binary(next_run_at),
       do: to_string(schedule_score(next_run_at))

  defp schedule_due_score(_schedule), do: ""

  defp delete_schedule_lease_metadata(schedule_id) do
    case scan_keys(key("lease", "schedule:#{schedule_id}:*")) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        case command(["DEL" | keys]) do
          {:ok, _deleted} -> :ok
          {:error, reason} -> {:error, format_reason(reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_schedule(schedule_id, schedule_map) do
    schedule_map
    |> stringify_map()
    |> Map.put("schedule_id", schedule_id)
    |> Map.put_new("created_at", timestamp())
    |> Map.put("updated_at", timestamp())
  end

  defp schedule_score(iso_datetime) when is_binary(iso_datetime) do
    case DateTime.from_iso8601(iso_datetime) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 0
    end
  end

  defp schedule_score(_value), do: 0

  defp version_sort_value(version) do
    case Integer.parse(to_string(version)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp fetch_agents(_job_id, []), do: {:ok, []}

  defp fetch_agents(job_id, agent_ids) do
    keys = Enum.map(agent_ids, &key("job", job_id, "agent", &1))

    case command(["MGET" | keys]) do
      {:ok, encoded_agents} -> {:ok, decode_json_items(encoded_agents)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp fetch_recovery_evals([]), do: {:ok, []}

  defp fetch_recovery_evals(eval_ids) do
    keys =
      eval_ids
      |> Enum.sort()
      |> Enum.map(&key("recovery", "eval", &1))

    case command(["MGET" | keys]) do
      {:ok, encoded_evals} ->
        encoded_evals
        |> decode_json_items()
        |> Enum.sort_by(&Map.get(&1, "created_at", ""))
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp recovery_eval_ids_by_status([]), do: {:ok, []}

  defp recovery_eval_ids_by_status([status]) do
    case command(["SMEMBERS", key("recovery", "evals", "status", status)]) do
      {:ok, eval_ids} -> {:ok, eval_ids}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp recovery_eval_ids_by_status(statuses) do
    keys = Enum.map(statuses, &key("recovery", "evals", "status", &1))

    case command(["SUNION" | keys]) do
      {:ok, eval_ids} -> {:ok, eval_ids}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp decode_json_items(items) do
    items
    |> Enum.map(fn
      nil ->
        nil

      encoded ->
        case Jason.decode(encoded) do
          {:ok, item} -> item
          {:error, _reason} -> nil
        end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp repair_job_index(redis_keys, indexed_job_ids) do
    root_job_ids =
      redis_keys
      |> Enum.flat_map(&root_job_id_from_key/1)
      |> Enum.uniq()

    indexed_job_ids = Enum.uniq(indexed_job_ids)
    indexed_job_set = MapSet.new(indexed_job_ids)

    repaired_jobs =
      root_job_ids
      |> Enum.filter(&(json_key_status(key("job", &1)) == :valid))
      |> Enum.reject(&MapSet.member?(indexed_job_set, &1))
      |> Enum.count(fn job_id ->
        case command(["SADD", key(@jobs_set), job_id]) do
          {:ok, count} when is_integer(count) -> count > 0
          _ -> false
        end
      end)

    removed_stale_jobs =
      indexed_job_ids
      |> Enum.filter(&(json_key_status(key("job", &1)) in [:missing, :corrupt]))
      |> Enum.count(fn job_id ->
        case command(["SREM", key(@jobs_set), job_id]) do
          {:ok, count} when is_integer(count) -> count > 0
          _ -> false
        end
      end)

    {:ok, %{repaired_jobs: repaired_jobs, removed_stale_jobs: removed_stale_jobs}}
  end

  defp repair_agent_indexes(redis_keys, indexed_job_ids) do
    agent_refs =
      redis_keys
      |> Enum.flat_map(&agent_ref_from_key/1)
      |> Enum.uniq()

    job_ids =
      (indexed_job_ids ++
         Enum.map(agent_refs, &elem(&1, 0)) ++
         Enum.flat_map(redis_keys, &root_job_id_from_key/1) ++
         Enum.flat_map(redis_keys, &agent_index_job_id_from_key/1))
      |> Enum.uniq()

    repaired_agents =
      agent_refs
      |> Enum.filter(fn {job_id, agent_id} ->
        json_key_status(key("job", job_id, "agent", agent_id)) == :valid
      end)
      |> Enum.count(fn {job_id, agent_id} ->
        case command(["SISMEMBER", key("job", job_id, "agents"), agent_id]) do
          {:ok, 1} ->
            false

          {:ok, 0} ->
            case command(["SADD", key("job", job_id, "agents"), agent_id]) do
              {:ok, count} when is_integer(count) -> count > 0
              _ -> false
            end

          _ ->
            false
        end
      end)

    removed_stale_agents =
      job_ids
      |> Enum.flat_map(fn job_id ->
        case command(["SMEMBERS", key("job", job_id, "agents")]) do
          {:ok, agent_ids} -> Enum.map(agent_ids, &{job_id, &1})
          _ -> []
        end
      end)
      |> Enum.filter(fn {job_id, agent_id} ->
        json_key_status(key("job", job_id, "agent", agent_id)) in [:missing, :corrupt]
      end)
      |> Enum.count(fn {job_id, agent_id} ->
        case command(["SREM", key("job", job_id, "agents"), agent_id]) do
          {:ok, count} when is_integer(count) -> count > 0
          _ -> false
        end
      end)

    {:ok, %{repaired_agents: repaired_agents, removed_stale_agents: removed_stale_agents}}
  end

  defp repair_recovery_eval_indexes do
    case recovery_eval_index_ids() do
      {:ok, eval_ids} ->
        result =
          Enum.reduce(
            eval_ids,
            %{repaired_recovery_evals: 0, removed_stale_recovery_evals: 0},
            fn eval_id, acc ->
              case fetch_recovery_eval(eval_id) do
                {:ok, eval} when is_map(eval) ->
                  if repair_recovery_eval_status_index(eval_id, Map.get(eval, "status")) do
                    Map.update!(acc, :repaired_recovery_evals, &(&1 + 1))
                  else
                    acc
                  end

                {:error, reason} ->
                  if missing_recovery_eval?(eval_id, reason) or corrupt_json?(reason) do
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
        {:error, format_reason(reason)}
    end
  end

  defp repair_recovery_eval_status_index(eval_id, status) do
    case transaction(recovery_eval_status_index_commands(eval_id, status)) do
      {:ok, [count | rest]} when is_integer(count) ->
        count > 0 or Enum.any?(rest, fn value -> is_integer(value) and value > 0 end)

      _ ->
        false
    end
  end

  defp sweep_recovery_eval_retention do
    ttl_seconds = recovery_eval_ttl_seconds()

    case recovery_eval_index_ids() do
      {:ok, eval_ids} ->
        result =
          Enum.reduce(
            eval_ids,
            %{
              deleted_recovery_evals: [],
              stale_recovery_evals: []
            },
            fn eval_id, acc ->
              case fetch_recovery_eval(eval_id) do
                {:ok, eval} when is_map(eval) ->
                  if terminal_recovery_eval_expired?(eval, ttl_seconds) do
                    _ = remove_stale_recovery_eval_index(eval_id)
                    Map.update!(acc, :deleted_recovery_evals, &[eval_id | &1])
                  else
                    :ok = apply_recovery_eval_retention(eval_id, Map.get(eval, "status"))
                    acc
                  end

                {:error, reason} ->
                  if missing_recovery_eval?(eval_id, reason) do
                    _ = remove_stale_recovery_eval_index(eval_id)
                    Map.update!(acc, :stale_recovery_evals, &[eval_id | &1])
                  else
                    Logger.warning(
                      "retention could not classify recovery eval #{eval_id}; cleanup deferred: #{inspect(reason)}"
                    )

                    acc
                  end
              end
            end
          )

        deleted_recovery_evals = Enum.reverse(result.deleted_recovery_evals)
        stale_recovery_evals = Enum.reverse(result.stale_recovery_evals)

        {:ok,
         %{
           deleted_recovery_eval_count: length(deleted_recovery_evals),
           stale_recovery_eval_count: length(stale_recovery_evals),
           deleted_recovery_evals: deleted_recovery_evals,
           stale_recovery_evals: stale_recovery_evals
         }}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp recovery_eval_index_ids do
    index_keys = [key("recovery", "evals") | recovery_eval_status_index_keys()]

    case pipeline(Enum.map(index_keys, &["SMEMBERS", &1])) do
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
        {:error, format_reason(reason)}
    end
  end

  defp remove_stale_recovery_eval_index(eval_id) do
    commands =
      [
        ["DEL", key("recovery", "eval", eval_id)],
        ["SREM", key("recovery", "evals"), eval_id]
        | Enum.map(@recovery_eval_statuses, fn status ->
            ["SREM", key("recovery", "evals", "status", status), eval_id]
          end)
      ]

    case transaction(commands) do
      {:ok, [_deleted, removed | _]} when is_integer(removed) -> removed > 0
      _ -> false
    end
  end

  defp json_key_status(redis_key) do
    case command(["GET", redis_key]) do
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

  defp root_job_id_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["job", job_id] -> [job_id]
      _ -> []
    end
  end

  defp bundle_archive_ref_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["bundle", fingerprint] -> [{fingerprint, redis_key}]
      _ -> []
    end
  end

  defp agent_ref_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["job", job_id, "agent", agent_id] -> [{job_id, agent_id}]
      _ -> []
    end
  end

  defp agent_index_job_id_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["job", job_id, "agents"] -> [job_id]
      _ -> []
    end
  end

  defp namespaced_key_parts(redis_key) when is_binary(redis_key) do
    prefix = namespace() <> ":"

    if String.starts_with?(redis_key, prefix) do
      redis_key
      |> String.replace_prefix(prefix, "")
      |> String.split(":")
    else
      []
    end
  end

  defp namespaced_key_parts(_redis_key), do: []

  defp validate_job_lease_epoch(job_id, job_map) do
    incoming = lease_epoch(job_map)

    case {incoming, existing_job_lease_epoch(job_id)} do
      {nil, _existing} ->
        :ok

      {_incoming, nil} ->
        :ok

      {incoming, existing} when incoming >= existing ->
        :ok

      {incoming, existing} ->
        {:error, {:stale_lease_epoch, incoming, existing}}
    end
  end

  defp persist_disk_job(job_id, job_map) do
    case DiskCheckpoint.persist_job(job_id, job_map) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist disk job checkpoint for #{job_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp persist_disk_agent(job_id, agent_id, snapshot) do
    DiskCheckpoint.with_job_lock(job_id, fn ->
      case fetch_job(job_id) do
        {:ok, %{"status" => status}} when status in @terminal_statuses ->
          _ = DiskCheckpoint.delete_job(job_id)
          :ok

        _ ->
          case DiskCheckpoint.persist_agent(job_id, agent_id, snapshot) do
            :ok ->
              :ok

            {:error, reason} ->
              handle_disk_agent_failure(job_id, agent_id, reason)
          end
      end
    end)
  end

  defp handle_disk_agent_failure(job_id, _agent_id, :enoent) do
    case fetch_job(job_id) do
      {:ok, %{"status" => status}} when status in @terminal_statuses ->
        _ = DiskCheckpoint.delete_job(job_id)
        :ok

      {:error, reason} when is_binary(reason) ->
        if String.contains?(reason, "was not found") do
          :ok
        else
          Logger.warning("failed to persist disk agent checkpoint for #{job_id}: :enoent")
          :ok
        end

      _ ->
        Logger.warning("failed to persist disk agent checkpoint for #{job_id}: :enoent")
        :ok
    end
  end

  defp handle_disk_agent_failure(job_id, agent_id, reason) do
    Logger.warning(
      "failed to persist disk agent checkpoint for #{job_id}/#{agent_id}: #{inspect(reason)}"
    )

    :ok
  end

  defp persist_disk_agents(job_id, agents) do
    Enum.reduce_while(agents, :ok, fn agent, :ok ->
      agent_id = Map.get(agent, "agent_id") || Map.get(agent, "node_id")

      case DiskCheckpoint.persist_agent(job_id, agent_id, agent) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_terminal_disk_checkpoint(job_id, job_map) do
    if terminal_status?(Map.get(job_map, "status") || Map.get(job_map, :status)) do
      case DiskCheckpoint.delete_job(job_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "failed to clean terminal disk checkpoint for #{job_id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp validate_agent_lease_epoch(job_id, snapshot) do
    incoming = lease_epoch(snapshot)

    case {incoming, existing_job_lease_epoch(job_id)} do
      {nil, _existing} ->
        :ok

      {_incoming, nil} ->
        :ok

      {incoming, existing} when incoming >= existing ->
        :ok

      {incoming, existing} ->
        {:error, {:stale_lease_epoch, incoming, existing}}
    end
  end

  defp existing_job_lease_epoch(job_id) do
    case command(["GET", key("job", job_id)]) do
      {:ok, nil} ->
        nil

      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, job} -> lease_epoch(job)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp lease_epoch(map) when is_map(map) do
    direct =
      Map.get(map, "lease_epoch") ||
        Map.get(map, :lease_epoch) ||
        get_in(map, ["lease", "epoch"]) ||
        get_in(map, [:lease, :epoch]) ||
        get_in(map, ["metadata", "lease_epoch"]) ||
        get_in(map, [:metadata, :lease_epoch])

    parse_integer(direct)
  end

  defp lease_epoch(_other), do: nil

  defp lease_payload(owner_id, epoch, ttl_ms) do
    %{"owner_id" => owner_id, "epoch" => parse_integer(epoch), "ttl_ms" => ttl_ms}
  end

  defp fenced_lease_value(owner_id, epoch), do: "#{owner_id}|#{epoch}"

  defp parse_fenced_lease(nil), do: nil

  defp parse_fenced_lease(value) when is_binary(value) do
    case String.split(value, "|", parts: 2) do
      [owner_id, epoch] -> lease_payload(owner_id, epoch, nil)
      [owner_id] -> %{"owner_id" => owner_id, "epoch" => nil, "ttl_ms" => nil}
    end
  end

  defp parse_fenced_lease(value),
    do: %{"owner_id" => inspect(value), "epoch" => nil, "ttl_ms" => nil}

  defp apply_job_retention(job_id, job_map) do
    if terminal_status?(Map.get(job_map, "status") || Map.get(job_map, :status)) do
      with :ok <- expire_terminal_job(job_id),
           do: expire_job_deliveries(job_id, 60 * 60)
    else
      persist_active_job(job_id)
    end
  end

  defp persist_active_job(job_id) do
    [
      key("job", job_id),
      key("job", job_id, "summary"),
      key("job", job_id, "events"),
      key("job", job_id, "agents")
    ]
    |> Enum.each(&persist_key/1)

    :ok
  end

  defp expire_terminal_job(job_id) do
    ttl_seconds = terminal_job_ttl_seconds()

    [
      key("job", job_id),
      key("job", job_id, "summary"),
      key("job", job_id, "events"),
      key("job", job_id, "agents")
    ]
    |> Enum.each(&expire_key(&1, ttl_seconds))

    case command(["SMEMBERS", key("job", job_id, "agents")]) do
      {:ok, agent_ids} ->
        Enum.each(agent_ids, fn agent_id ->
          expire_key(key("job", job_id, "agent", agent_id), agent_snapshot_ttl_seconds())
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp event_retention_commands(event_key) do
    maybe_trim_event_log_command(event_key) ++
      maybe_expire_key_command(event_key, event_ttl_seconds())
  end

  defp maybe_trim_event_log_command(event_key) do
    case event_max_count() do
      max_count when is_integer(max_count) and max_count > 0 ->
        [["LTRIM", event_key, "-#{max_count}", "-1"]]

      _ ->
        []
    end
  end

  defp expire_agent_snapshot_commands(job_id, agent_id) do
    ttl_seconds = agent_snapshot_ttl_seconds()

    maybe_expire_key_command(key("job", job_id, "agent", agent_id), ttl_seconds) ++
      maybe_expire_key_command(key("job", job_id, "agents"), ttl_seconds)
  end

  defp agent_snapshot_retention_commands(job_id, agent_id) do
    case fetch_job(job_id) do
      {:ok, job} ->
        if terminal_status?(Map.get(job, "status")) do
          expire_agent_snapshot_commands(job_id, agent_id)
        else
          [
            ["PERSIST", key("job", job_id, "agent", agent_id)],
            ["PERSIST", key("job", job_id, "agents")]
          ]
        end

      {:error, _reason} ->
        expire_agent_snapshot_commands(job_id, agent_id)
    end
  end

  defp maybe_expire_key_command(_redis_key, ttl_seconds)
       when not is_integer(ttl_seconds) or ttl_seconds <= 0,
       do: []

  defp maybe_expire_key_command(redis_key, ttl_seconds),
    do: [["EXPIRE", redis_key, to_string(ttl_seconds)]]

  defp expire_key(_redis_key, ttl_seconds) when not is_integer(ttl_seconds) or ttl_seconds <= 0,
    do: :ok

  defp expire_key(redis_key, ttl_seconds) do
    _ = command(["EXPIRE", redis_key, to_string(ttl_seconds)])
    :ok
  end

  defp persist_key(redis_key) do
    _ = command(["PERSIST", redis_key])
    :ok
  end

  defp compact_recovery_eval(eval) when is_map(eval), do: Map.take(eval, @recovery_eval_fields)
  defp compact_recovery_eval(eval), do: eval

  defp recovery_eval_retention_commands(eval_id, status) do
    eval_key = key("recovery", "eval", eval_id)

    if terminal_recovery_eval_status?(status) do
      maybe_expire_key_command(eval_key, recovery_eval_ttl_seconds())
    else
      [["PERSIST", eval_key]]
    end
  end

  defp apply_recovery_eval_retention(eval_id, status) do
    eval_key = key("recovery", "eval", eval_id)

    if terminal_recovery_eval_status?(status) do
      expire_key(eval_key, recovery_eval_ttl_seconds())
    else
      persist_key(eval_key)
    end
  end

  defp terminal_recovery_eval_expired?(_eval, ttl_seconds) when ttl_seconds < 0, do: false

  defp terminal_recovery_eval_expired?(eval, ttl_seconds) do
    terminal_recovery_eval_status?(Map.get(eval, "status")) and
      recovery_eval_age_seconds(eval) >= ttl_seconds
  end

  defp terminal_recovery_eval_status?(status),
    do: to_string(status || "") in @terminal_recovery_eval_statuses

  defp recovery_eval_age_seconds(eval) do
    updated_at =
      Map.get(eval, "completed_at") ||
        Map.get(eval, "updated_at") ||
        Map.get(eval, "created_at") ||
        timestamp()

    with true <- is_binary(updated_at),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(updated_at) do
      DateTime.diff(DateTime.utc_now(), datetime, :second)
    else
      _ -> 0
    end
  end

  defp terminal_job_expired?(_job, ttl_seconds) when ttl_seconds < 0, do: false

  defp terminal_job_expired?(job, ttl_seconds) do
    terminal_status?(Map.get(job, "status")) and job_age_seconds(job) >= ttl_seconds
  end

  defp missing_job?(job_id, reason), do: reason == "job #{job_id} was not found"

  defp missing_deployment?(deployment_id, reason),
    do: reason == "deployment #{deployment_id} was not found"

  defp missing_deployment_version?(deployment_key, version, reason),
    do: reason == "deployment #{deployment_key} version #{version} was not found"

  defp missing_node_state?(node_name, reason),
    do: reason == "node #{node_name} state was not found"

  defp missing_schedule?(schedule_id, reason),
    do: reason == "schedule #{schedule_id} was not found"

  defp missing_recovery_eval?(eval_id, reason),
    do: reason == "recovery eval #{eval_id} was not found"

  defp corrupt_node_state?(:invalid_node_state), do: true
  defp corrupt_node_state?(reason), do: corrupt_json?(reason)

  defp corrupt_deployment?(:invalid_deployment), do: true
  defp corrupt_deployment?(reason), do: corrupt_json?(reason)

  defp corrupt_deployment_version?(:invalid_deployment_version), do: true
  defp corrupt_deployment_version?(reason), do: corrupt_json?(reason)

  defp corrupt_schedule?(:invalid_schedule), do: true
  defp corrupt_schedule?(reason), do: corrupt_json?(reason)

  defp corrupt_json?(%Jason.DecodeError{}), do: true
  defp corrupt_json?(_reason), do: false

  defp terminal_status?(status), do: status in @terminal_statuses

  defp job_age_seconds(job) do
    updated_at = Map.get(job, "updated_at") || Map.get(job, "submitted_at") || timestamp()

    with true <- is_binary(updated_at),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(updated_at) do
      DateTime.diff(DateTime.utc_now(), datetime, :second)
    else
      _ -> 0
    end
  end

  defp terminal_job_ttl_seconds do
    config_integer(
      "MN_TERMINAL_JOB_TTL_SECONDS",
      :terminal_job_ttl_seconds,
      @default_terminal_job_ttl_seconds
    )
  end

  defp event_ttl_seconds do
    config_integer(
      "MN_EVENT_TTL_SECONDS",
      :event_ttl_seconds,
      @default_event_ttl_seconds
    )
  end

  defp event_max_count do
    config_integer("MN_EVENT_MAX_COUNT", :event_max_count, @default_event_max_count)
  end

  defp agent_snapshot_ttl_seconds do
    config_integer(
      "MN_AGENT_SNAPSHOT_TTL_SECONDS",
      :agent_snapshot_ttl_seconds,
      @default_agent_snapshot_ttl_seconds
    )
  end

  defp bundle_archive_ttl_seconds do
    config_integer(
      "MN_BUNDLE_ARCHIVE_TTL_SECONDS",
      :bundle_archive_ttl_seconds,
      @default_bundle_archive_ttl_seconds
    )
  end

  defp blob_ref_ttl_seconds do
    config_integer(
      "MN_BLOB_REF_TTL_SECONDS",
      :blob_ref_ttl_seconds,
      @default_blob_ref_ttl_seconds
    )
  end

  defp recovery_eval_ttl_seconds do
    config_integer(
      "MN_RECOVERY_EVAL_TTL_SECONDS",
      :recovery_eval_ttl_seconds,
      @default_recovery_eval_ttl_seconds
    )
  end

  defp config_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil ->
        Application.get_env(:mirror_neuron, key, default)

      "" ->
        Application.get_env(:mirror_neuron, key, default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end

  defp ensure_delivery_group(stream_key, stream_ttl_seconds) do
    case command([
           "XGROUP",
           "CREATE",
           stream_key,
           @delivery_consumer_group,
           "0",
           "MKSTREAM"
         ]) do
      {:ok, "OK"} ->
        case command(["EXPIRE", stream_key, to_string(stream_ttl_seconds)]) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, format_reason(reason)}
        end

      {:error, %Redix.Error{message: message}} when is_binary(message) ->
        if String.contains?(message, "BUSYGROUP"), do: :ok, else: {:error, message}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_group_result, other}}
    end
  end

  defp maybe_ensure_delivery_group(stream_key, stream_ttl_seconds, true),
    do: ensure_delivery_group(stream_key, stream_ttl_seconds)

  defp maybe_ensure_delivery_group(_stream_key, _stream_ttl_seconds, false), do: :ok

  defp claim_stale_deliveries(stream_key, consumer, lease_ms, count) when count > 0 do
    case command([
           "XAUTOCLAIM",
           stream_key,
           @delivery_consumer_group,
           consumer,
           to_string(lease_ms),
           "0-0",
           "COUNT",
           to_string(count)
         ]) do
      {:ok, [_next_start, entries | _deleted]} -> {:ok, parse_delivery_entries(entries)}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_claim_result, other}}
    end
  end

  defp claim_stale_deliveries(_stream_key, _consumer, _lease_ms, _count), do: {:ok, []}

  defp maybe_claim_stale_deliveries(stream_key, consumer, lease_ms, count, true),
    do: claim_stale_deliveries(stream_key, consumer, lease_ms, count)

  defp maybe_claim_stale_deliveries(_stream_key, _consumer, _lease_ms, _count, false),
    do: {:ok, []}

  defp read_new_deliveries(stream_key, consumer, count) when count > 0 do
    case command([
           "XREADGROUP",
           "GROUP",
           @delivery_consumer_group,
           consumer,
           "COUNT",
           to_string(count),
           "STREAMS",
           stream_key,
           ">"
         ]) do
      {:ok, nil} -> {:ok, []}
      {:ok, [[^stream_key, entries]]} -> {:ok, parse_delivery_entries(entries)}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_read_result, other}}
    end
  end

  defp read_new_deliveries(_stream_key, _consumer, _count), do: {:ok, []}

  defp parse_delivery_entries(entries) when is_list(entries) do
    Enum.map(entries, fn [stream_id, fields] ->
      fields = pairs_to_map(fields)

      %{
        stream_id: stream_id,
        message_id: fields["message_id"],
        payload: fields["payload"]
      }
    end)
  end

  defp pairs_to_map(values) when is_list(values) do
    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  defp prepare_delivery(job_id, agent_id, consumer, entry, now_ms, max_attempts) do
    receipt_key = delivery_receipt_key(job_id, agent_id, entry.message_id)

    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      return {"missing", "0"}
    end
    local status = redis.call("hget", KEYS[1], "status") or "unknown"
    if status == "acked" or status == "dead_letter" then
      return {status, redis.call("hget", KEYS[1], "attempts") or "0"}
    end
    local deadline_ms = tonumber(redis.call("hget", KEYS[1], "deadline_ms") or "0")
    if deadline_ms > 0 and tonumber(ARGV[1]) > deadline_ms then
      return {"expired", redis.call("hget", KEYS[1], "attempts") or "0"}
    end
    local attempts = redis.call("hincrby", KEYS[1], "attempts", 1)
    if attempts > tonumber(ARGV[2]) then
      return {"attempts_exhausted", tostring(attempts)}
    end
    redis.call("hset", KEYS[1], "status", "processing", "consumer", ARGV[3])
    return {"deliver", tostring(attempts)}
    """

    case command([
           "EVAL",
           script,
           "1",
           receipt_key,
           to_string(now_ms),
           to_string(max_attempts),
           consumer
         ]) do
      {:ok, ["deliver", attempts]} ->
        case Jason.decode(entry.payload) do
          {:ok, message} ->
            {:ok,
             Map.merge(entry, %{
               message: message,
               attempt: parse_redis_integer(attempts)
             })}

          {:error, reason} ->
            {:discard, Map.merge(entry, %{discard_reason: {:invalid_payload, reason}})}
        end

      {:ok, [reason, attempts]}
      when reason in ["missing", "acked", "dead_letter", "expired", "attempts_exhausted"] ->
        {:discard,
         Map.merge(entry, %{
           discard_reason: String.to_atom(reason),
           attempt: parse_redis_integer(attempts)
         })}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_prepare_result, other}}
    end
  end

  defp parse_delivery_receipt(receipt) do
    receipt
    |> Map.update("attempts", 0, &parse_redis_integer/1)
    |> Map.update("deadline_ms", 0, &parse_redis_integer/1)
    |> Map.update("enqueued_at_ms", 0, &parse_redis_integer/1)
  end

  defp parse_redis_integer(value) when is_integer(value), do: value

  defp parse_redis_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp parse_redis_integer(_value), do: 0

  defp delivery_stream_key(job_id, agent_id),
    do: key("job", job_id, "agent", agent_id, "deliveries")

  defp delivery_receipt_key(job_id, agent_id, message_id),
    do: key("job", job_id, "delivery", agent_id, message_id)

  defp delivery_agent_count_key(job_id, agent_id),
    do: key("job", job_id, "delivery_count", agent_id)

  defp delivery_job_count_key(job_id), do: key("job", job_id, "delivery_count")
  defp delivery_index_key(job_id), do: key("job", job_id, "delivery_keys")

  defp command(args), do: command(args, redis_reconnect_attempts(), redis_reconnect_backoff_ms())

  def redis_command_from_peer(args) when is_list(args) do
    safe_command(MirrorNeuron.Redis.Connection, args)
  end

  def redis_pipeline_from_peer(commands) when is_list(commands) do
    safe_pipeline(MirrorNeuron.Redis.Connection, commands)
  end

  defp command(args, attempts_left, backoff_ms) do
    case maybe_forward_command(args) do
      :local ->
        command_local(args, attempts_left, backoff_ms)

      {:forwarded, result} ->
        result
    end
  end

  defp command_local(args, attempts_left, backoff_ms) do
    case safe_command(MirrorNeuron.Redis.Connection, args) do
      {:error, reason} = error ->
        cond do
          readonly_error?(reason) ->
            forward_or_error(:redis_command_from_peer, [args], error)

          attempts_left > 0 and reconnectable_error?(reason) ->
            _ = MirrorNeuron.Redis.reconnect()
            Process.sleep(backoff_ms)
            command_local(args, attempts_left - 1, next_reconnect_backoff(backoff_ms))

          true ->
            error
        end

      other ->
        other
    end
  end

  defp maybe_forward_command(args) do
    case forwarding_primary_node() do
      {:ok, node} ->
        case safe_node_rpc_call(node, __MODULE__, :redis_command_from_peer, [args], 5_000) do
          {:badrpc, _reason} -> :local
          result -> {:forwarded, result}
        end

      :local ->
        :local
    end
  end

  defp forward_or_error(function, args, fallback) do
    case primary_redis_node() do
      nil ->
        fallback

      node ->
        case safe_node_rpc_call(node, __MODULE__, function, args, 5_000) do
          {:badrpc, _reason} -> fallback
          result -> result
        end
    end
  end

  defp forwarding_primary_node do
    enabled? =
      "MN_REDIS_FORWARD_PRIMARY"
      |> System.get_env("false")
      |> String.downcase()
      |> Kernel.in(["1", "true", "yes", "on"])

    if enabled? do
      case primary_redis_node() do
        nil -> :local
        node -> {:ok, node}
      end
    else
      :local
    end
  end

  defp primary_redis_node do
    Enum.find(NodeAdapter.list(), fn node ->
      case safe_node_rpc_call(node, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000) do
        false -> true
        _ -> false
      end
    end)
  end

  defp readonly_error?(%Redix.Error{message: message}) when is_binary(message) do
    message
    |> String.upcase()
    |> String.contains?("READONLY")
  end

  defp readonly_error?(_reason), do: false

  defp safe_command(connection, args) do
    Redix.command(connection, args)
  catch
    :exit, {:redix_exited_during_call, reason} ->
      {:error, {:redix_exited_during_call, reason}}

    :exit, {:noproc, _} = reason ->
      {:error, {:redix_exit, reason}}

    :exit, reason ->
      {:error, {:redix_exit, reason}}
  end

  defp transaction(commands),
    do: transaction(commands, redis_reconnect_attempts(), redis_reconnect_backoff_ms())

  defp transaction(commands, attempts_left, backoff_ms) do
    transaction_commands = [["MULTI"] | commands] ++ [["EXEC"]]

    case pipeline(transaction_commands, attempts_left, backoff_ms) do
      {:ok, results} ->
        parse_transaction_results(results)

      {:error, reason} = error ->
        if attempts_left > 0 and reconnectable_error?(reason) do
          _ = MirrorNeuron.Redis.reconnect()
          Process.sleep(backoff_ms)
          transaction(commands, attempts_left - 1, next_reconnect_backoff(backoff_ms))
        else
          error
        end
    end
  end

  defp pipeline(commands),
    do: pipeline(commands, redis_reconnect_attempts(), redis_reconnect_backoff_ms())

  defp pipeline(commands, attempts_left, backoff_ms) do
    case maybe_forward_pipeline(commands) do
      :local ->
        pipeline_local(commands, attempts_left, backoff_ms)

      {:forwarded, result} ->
        result
    end
  end

  defp pipeline_local(commands, attempts_left, backoff_ms) do
    case safe_pipeline(MirrorNeuron.Redis.Connection, commands) do
      {:ok, results} ->
        case readonly_error_in_results(results) do
          nil -> {:ok, results}
          reason -> forward_or_error(:redis_pipeline_from_peer, [commands], {:error, reason})
        end

      {:error, reason} = error ->
        cond do
          readonly_error?(reason) ->
            forward_or_error(:redis_pipeline_from_peer, [commands], error)

          attempts_left > 0 and reconnectable_error?(reason) ->
            _ = MirrorNeuron.Redis.reconnect()
            Process.sleep(backoff_ms)
            pipeline_local(commands, attempts_left - 1, next_reconnect_backoff(backoff_ms))

          true ->
            error
        end
    end
  end

  defp readonly_error_in_results(results) when is_list(results) do
    Enum.find(results, &readonly_error?/1)
  end

  defp readonly_error_in_results(_results), do: nil

  defp maybe_forward_pipeline(commands) do
    case forwarding_primary_node() do
      {:ok, node} ->
        case safe_node_rpc_call(node, __MODULE__, :redis_pipeline_from_peer, [commands], 5_000) do
          {:badrpc, _reason} -> :local
          result -> {:forwarded, result}
        end

      :local ->
        :local
    end
  end

  defp safe_pipeline(connection, commands) do
    Redix.pipeline(connection, commands)
  catch
    :exit, {:redix_exited_during_call, reason} ->
      {:error, {:redix_exited_during_call, reason}}

    :exit, {:noproc, _} = reason ->
      {:error, {:redix_exit, reason}}

    :exit, reason ->
      {:error, {:redix_exit, reason}}
  end

  defp safe_node_rpc_call(node, module, function, args, timeout) do
    NodeAdapter.rpc_call(node, module, function, args, timeout)
  rescue
    exception -> {:badrpc, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:badrpc, {kind, reason}}
  end

  defp parse_transaction_results(["OK" | queued_and_exec]) do
    case List.last(queued_and_exec) do
      exec_results when is_list(exec_results) ->
        case Enum.find(Enum.drop(queued_and_exec, -1), &match?(%Redix.Error{}, &1)) do
          nil -> {:ok, exec_results}
          error -> {:error, format_reason(error)}
        end

      nil ->
        {:error, "missing Redis transaction EXEC result"}

      %Redix.Error{} = error ->
        {:error, format_reason(error)}

      other ->
        {:error, format_reason(other)}
    end
  end

  defp parse_transaction_results([%Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp parse_transaction_results(other), do: {:error, format_reason(other)}

  defp expect_persist_job_results(["OK", "OK", count]) when is_integer(count), do: :ok

  defp expect_persist_job_results([%Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp expect_persist_job_results([_set, %Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp expect_persist_job_results([_set, _summary, %Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp expect_persist_job_results(other), do: {:error, format_reason(other)}

  defp expect_persist_agent_results(["OK", count | _]) when is_integer(count), do: :ok

  defp expect_persist_agent_results([%Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp expect_persist_agent_results([_set, %Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp expect_persist_agent_results(other), do: {:error, format_reason(other)}

  defp expect_first_result([%Redix.Error{} = error | _], _predicate),
    do: {:error, format_reason(error)}

  defp expect_first_result([value | _], predicate) do
    if predicate.(value), do: :ok, else: {:error, format_reason(value)}
  end

  defp expect_first_result([], _predicate), do: {:error, "missing Redis pipeline result"}

  defp expect_no_redis_errors(results) when is_list(results) do
    case Enum.find(results, &match?(%Redix.Error{}, &1)) do
      nil -> :ok
      %Redix.Error{} = error -> {:error, format_reason(error)}
    end
  end

  defp expect_no_redis_errors(other), do: {:error, format_reason(other)}

  defp recovery_eval_status_index_keys do
    Enum.map(@recovery_eval_statuses, &key("recovery", "evals", "status", &1))
  end

  defp recovery_eval_status_index_commands(eval_id, status) do
    status = recovery_eval_status(status)

    [
      ["SADD", key("recovery", "evals", "status", status), eval_id]
      | Enum.map(@recovery_eval_statuses -- [status], fn old_status ->
          ["SREM", key("recovery", "evals", "status", old_status), eval_id]
        end)
    ]
  end

  defp recovery_eval_status(nil), do: "pending"
  defp recovery_eval_status(status), do: to_string(status)

  defp raw_job_ids do
    case command(["SMEMBERS", key(@jobs_set)]) do
      {:ok, job_ids} -> {:ok, job_ids}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp scan_keys(pattern), do: scan_keys(pattern, "0", [])

  defp scan_keys(pattern, cursor, acc) do
    case command(["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [next_cursor, keys]} ->
        next_acc = acc ++ keys

        if next_cursor == "0" do
          {:ok, next_acc}
        else
          scan_keys(pattern, next_cursor, next_acc)
        end

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp reconnectable_error?(reason), do: MirrorNeuron.Redis.reconnectable_error?(reason)

  defp redis_reconnect_attempts do
    config_integer("MN_REDIS_RECONNECT_ATTEMPTS", :redis_reconnect_attempts, 10)
  end

  defp redis_reconnect_backoff_ms do
    config_integer("MN_REDIS_RECONNECT_BACKOFF_MS", :redis_reconnect_backoff_ms, 250)
  end

  defp redis_reconnect_max_backoff_ms do
    config_integer(
      "MN_REDIS_RECONNECT_MAX_BACKOFF_MS",
      :redis_reconnect_max_backoff_ms,
      2_000
    )
  end

  defp next_reconnect_backoff(backoff_ms) do
    min(backoff_ms * 2, redis_reconnect_max_backoff_ms())
  end

  defp wait_for_replicas do
    wait_replicas = config_integer("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas, 0)

    wait_timeout_ms =
      config_integer("MN_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms, 100)

    cond do
      wait_replicas <= 0 ->
        :ok

      true ->
        case command(["WAIT", to_string(wait_replicas), to_string(wait_timeout_ms)]) do
          {:ok, acknowledgements}
          when is_integer(acknowledgements) and acknowledgements >= wait_replicas ->
            :ok

          {:ok, acknowledgements} ->
            {:error, {:redis_replication_wait_timeout, acknowledgements, wait_replicas}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp key(part1), do: Enum.join([namespace(), part1], ":")
  defp key(part1, part2), do: Enum.join([namespace(), part1, part2], ":")
  defp key(part1, part2, part3), do: Enum.join([namespace(), part1, part2, part3], ":")

  defp key(part1, part2, part3, part4),
    do: Enum.join([namespace(), part1, part2, part3, part4], ":")

  defp key(part1, part2, part3, part4, part5),
    do: Enum.join([namespace(), part1, part2, part3, part4, part5], ":")

  defp channel(part1, part2), do: Enum.join([namespace(), "channel", part1, part2], ":")

  defp namespace,
    do: Config.string("MN_REDIS_NAMESPACE", :redis_namespace)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
