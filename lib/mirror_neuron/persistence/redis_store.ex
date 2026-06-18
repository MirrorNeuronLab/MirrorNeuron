defmodule MirrorNeuron.Persistence.RedisStore do
  alias MirrorNeuron.Artifacts.{JobStore, SharedStorage}
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Config
  alias MirrorNeuron.JobId

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

  def persist_job(job_id, job_map) do
    encoded = Jason.encode!(job_map)

    with :ok <- validate_job_lease_epoch(job_id, job_map),
         {:ok, results} <-
           transaction([
             ["SET", key("job", job_id), encoded],
             ["SADD", key(@jobs_set), job_id]
           ]),
         :ok <- expect_persist_job_results(results),
         :ok <- apply_job_retention(job_id, job_map),
         :ok <- wait_for_replicas() do
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

  def persist_schedule(schedule_id, schedule_map) do
    schedule =
      schedule_map
      |> stringify_map()
      |> Map.put("schedule_id", schedule_id)
      |> Map.put_new("created_at", timestamp())
      |> Map.put("updated_at", timestamp())

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

  def fetch_schedule(schedule_id) do
    case command(["GET", key("schedule", schedule_id)]) do
      {:ok, nil} -> {:error, "schedule #{schedule_id} was not found"}
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_schedules do
    with {:ok, schedule_ids} <- command(["SMEMBERS", key(@schedules_set)]) do
      schedule_ids
      |> Enum.sort()
      |> Enum.map(&fetch_schedule/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, schedule} -> schedule end)
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_due_schedules(now_iso) do
    score = schedule_score(now_iso)

    with {:ok, schedule_ids} <-
           command(["ZRANGEBYSCORE", key(@schedule_due_zset), "-inf", to_string(score)]) do
      schedule_ids
      |> Enum.sort()
      |> Enum.map(&fetch_schedule/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, schedule} -> schedule end)
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def delete_schedule(schedule_id) do
    with {:ok, _results} <-
           transaction([
             ["DEL", key("schedule", schedule_id)],
             ["SREM", key(@schedules_set), schedule_id],
             ["ZREM", key(@schedule_due_zset), schedule_id]
           ]),
         :ok <- wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
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
             ["SET", key("trigger", "event", event_id), encoded],
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

    commands =
      [
        ["SET", key("deployment", deployment_id), Jason.encode!(deployment)],
        ["SADD", key(@deployments_set), deployment_id]
      ] ++ deployment_index_commands(deployment_key, deployment_id)

    with {:ok, results} <- transaction(commands),
         :ok <- expect_first_result(results, fn value -> value == "OK" end),
         :ok <- wait_for_replicas() do
      {:ok, deployment}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def fetch_deployment(deployment_id) do
    case command(["GET", key("deployment", deployment_id)]) do
      {:ok, nil} -> {:error, "deployment #{deployment_id} was not found"}
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def fetch_deployment_by_key(deployment_key) do
    case command(["GET", key("deployment", "key", deployment_key, "current")]) do
      {:ok, nil} -> {:error, "deployment #{deployment_key} was not found"}
      {:ok, deployment_id} -> fetch_deployment(deployment_id)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def fetch_deployment_ref(id_or_key) do
    case fetch_deployment(id_or_key) do
      {:ok, deployment} ->
        {:ok, deployment}

      {:error, _reason} ->
        fetch_deployment_by_key(id_or_key)
    end
  end

  def list_deployments do
    with {:ok, deployment_ids} <- command(["SMEMBERS", key(@deployments_set)]) do
      deployments =
        deployment_ids
        |> Enum.sort()
        |> Enum.map(fn deployment_id ->
          case fetch_deployment(deployment_id) do
            {:ok, deployment} -> deployment
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, deployments}
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
      {:ok, nil} -> {:error, "deployment #{deployment_key} version #{version_id} was not found"}
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_job_versions(deployment_key) do
    with {:ok, versions} <-
           command(["SMEMBERS", key("deployment", "key", deployment_key, "versions")]) do
      records =
        versions
        |> Enum.sort_by(&version_sort_value/1)
        |> Enum.map(fn version ->
          case fetch_job_version(deployment_key, version) do
            {:ok, record} -> record
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, records}
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
         {:ok, results} <-
           transaction([
             ["SET", key("job", job_id, "agent", agent_id), encoded],
             ["SADD", key("job", job_id, "agents"), agent_id]
             | expire_agent_snapshot_commands(job_id, agent_id)
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
    job_map =
      case fetch_job(job_id) do
        {:ok, job} when is_map(job) -> job
        _ -> nil
      end

    _ = delete_service_instances(job_id: job_id)
    _ = SharedStorage.cleanup_job(job_id, job_map)
    _ = JobStore.cleanup_job(job_id)

    with {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]) do
      keys =
        [
          key("job", job_id),
          key("job", job_id, "events"),
          key("job", job_id, "agents")
        ] ++ Enum.map(agent_ids, &key("job", job_id, "agent", &1))

      _ = command(["DEL" | keys])
      _ = command(["SREM", key(@jobs_set), job_id])
      _ = wait_for_replicas()
      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  def sweep_retention(opts \\ []) do
    ttl_seconds = Keyword.get(opts, :terminal_job_ttl_seconds, terminal_job_ttl_seconds())

    with {:ok, job_ids} <- list_job_ids(),
         {:ok, eval_result} <- sweep_recovery_eval_retention() do
      result =
        Enum.reduce(job_ids, %{deleted_jobs: [], stale_job_ids: []}, fn job_id, acc ->
          case fetch_job(job_id) do
            {:ok, job} ->
              if terminal_job_expired?(job, ttl_seconds) do
                delete_job(job_id)
                Map.update!(acc, :deleted_jobs, &[job_id | &1])
              else
                acc
              end

            {:error, _reason} ->
              _ = command(["SREM", key(@jobs_set), job_id])
              _ = JobStore.cleanup_job(job_id)
              Map.update!(acc, :stale_job_ids, &[job_id | &1])
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
         stale_recovery_evals: Map.get(eval_result, :stale_recovery_evals, [])
       }}
    end
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

    commands =
      [
        ["SET", key("service", "instance", instance_id), Jason.encode!(service)],
        ["SADD", key("service", "instances"), instance_id]
      ] ++ service_index_commands("SADD", service, instance_id)

    with {:ok, results} <- transaction(commands),
         :ok <- expect_first_result(results, fn value -> value == "OK" end),
         :ok <- wait_for_replicas() do
      {:ok, service}
    else
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, format_reason(other)}
    end
  end

  def fetch_service_instance(instance_id) do
    case command(["GET", key("service", "instance", instance_id)]) do
      {:ok, nil} -> {:error, "service instance #{instance_id} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_service_instances(_opts \\ []) do
    case command(["SMEMBERS", key("service", "instances")]) do
      {:ok, ids} -> fetch_service_instances(Enum.sort(ids))
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def delete_service_instance(instance_id) do
    case fetch_service_instance(instance_id) do
      {:ok, service} ->
        commands =
          [
            ["DEL", key("service", "instance", instance_id)],
            ["SREM", key("service", "instances"), instance_id]
          ] ++ service_index_commands("SREM", service, instance_id)

        _ = transaction(commands)
        _ = wait_for_replicas()
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def delete_service_instances(opts) when is_list(opts) do
    with {:ok, services} <- list_service_instances() do
      services
      |> Enum.filter(&service_matches_opts?(&1, opts))
      |> Enum.each(fn service -> delete_service_instance(service["id"]) end)

      :ok
    else
      {:error, _reason} -> :ok
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
    with {:ok, sha_values} <- command(["SMEMBERS", key("blobs")]) do
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

  def persist_node_state(node_name, attrs) do
    state =
      attrs
      |> stringify_map()
      |> Map.put("node", node_name)
      |> Map.put("updated_at", timestamp())

    with {:ok, "OK"} <- command(["SET", key("node", node_name, "state"), Jason.encode!(state)]),
         {:ok, _count} <- command(["SADD", key("nodes"), node_name]),
         :ok <- wait_for_replicas() do
      {:ok, state}
    end
  end

  def fetch_node_state(node_name) do
    case command(["GET", key("node", node_name, "state")]) do
      {:ok, nil} -> {:error, "node #{node_name} state was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def list_node_states do
    case command(["SMEMBERS", key("nodes")]) do
      {:ok, node_names} ->
        states =
          node_names
          |> Enum.map(fn node_name ->
            case fetch_node_state(node_name) do
              {:ok, state} -> state
              {:error, _reason} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, states}

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

  defp fetch_service_instances([]), do: {:ok, []}

  defp fetch_service_instances(instance_ids) do
    keys = Enum.map(instance_ids, &key("service", "instance", &1))

    case command(["MGET" | keys]) do
      {:ok, encoded_services} -> {:ok, decode_json_items(encoded_services)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp service_index_commands(operation, service, instance_id) do
    []
    |> maybe_service_index(operation, service, instance_id, "name", ["service", "name"])
    |> maybe_service_index(operation, service, instance_id, "job_id", ["service", "job"])
    |> maybe_service_index(operation, service, instance_id, "node", ["service", "node"])
    |> maybe_service_index(operation, service, instance_id, "agent_id", ["service", "agent"])
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

  defp schedule_score(iso_datetime) when is_binary(iso_datetime) do
    case DateTime.from_iso8601(iso_datetime) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 0
    end
  end

  defp schedule_score(_value), do: 0

  defp deployment_index_commands(nil, _deployment_id), do: []
  defp deployment_index_commands("", _deployment_id), do: []

  defp deployment_index_commands(deployment_key, deployment_id) do
    [
      ["SET", key("deployment", "key", deployment_key, "current"), deployment_id],
      ["SADD", key("deployment", "key", deployment_key, "deployments"), deployment_id]
    ]
  end

  defp version_sort_value(version) do
    case Integer.parse(to_string(version)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp maybe_service_index(commands, operation, service, instance_id, field, key_parts) do
    case Map.get(service, field) do
      value when is_binary(value) and value != "" ->
        [service_index_command(operation, key_parts, value, instance_id) | commands]

      _ ->
        commands
    end
  end

  defp service_index_command(operation, ["service", index], value, instance_id),
    do: [operation, key("service", index, value), instance_id]

  defp service_matches_opts?(service, opts) do
    Enum.all?(opts, fn
      {:job_id, value} -> Map.get(service, "job_id") == to_string(value)
      {:agent_id, value} -> Map.get(service, "agent_id") == to_string(value)
      {:node, value} -> Map.get(service, "node") == to_string(value)
      {:name, value} -> Map.get(service, "name") == to_string(value)
      _other -> true
    end)
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
      |> Enum.filter(&(valid_job_key?(&1) and not MapSet.member?(indexed_job_set, &1)))
      |> Enum.count(fn job_id ->
        case command(["SADD", key(@jobs_set), job_id]) do
          {:ok, count} when is_integer(count) -> count > 0
          _ -> false
        end
      end)

    removed_stale_jobs =
      indexed_job_ids
      |> Enum.reject(&valid_job_key?/1)
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
      |> Enum.filter(fn {job_id, agent_id} -> valid_agent_key?(job_id, agent_id) end)
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
      |> Enum.reject(fn {job_id, agent_id} -> valid_agent_key?(job_id, agent_id) end)
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

                _ ->
                  if remove_stale_recovery_eval_index(eval_id) do
                    Map.update!(acc, :removed_stale_recovery_evals, &(&1 + 1))
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

                _ ->
                  _ = remove_stale_recovery_eval_index(eval_id)
                  Map.update!(acc, :stale_recovery_evals, &[eval_id | &1])
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

  defp valid_job_key?(job_id) do
    case command(["GET", key("job", job_id)]) do
      {:ok, encoded} when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, job} when is_map(job) -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_agent_key?(job_id, agent_id) do
    case command(["GET", key("job", job_id, "agent", agent_id)]) do
      {:ok, encoded} when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, agent} when is_map(agent) -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp root_job_id_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["job", job_id] -> [job_id]
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
      expire_terminal_job(job_id)
    else
      persist_active_job(job_id)
    end
  end

  defp persist_active_job(job_id) do
    [
      key("job", job_id),
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
        case NodeAdapter.rpc_call(node, __MODULE__, :redis_command_from_peer, [args], 5_000) do
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
        case NodeAdapter.rpc_call(node, __MODULE__, function, args, 5_000) do
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
      case NodeAdapter.rpc_call(node, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000) do
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

      other ->
        other
    end
  end

  defp maybe_forward_pipeline(commands) do
    case forwarding_primary_node() do
      {:ok, node} ->
        case NodeAdapter.rpc_call(node, __MODULE__, :redis_pipeline_from_peer, [commands], 5_000) do
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

  defp expect_persist_job_results(["OK", count]) when is_integer(count), do: :ok

  defp expect_persist_job_results([%Redix.Error{} = error | _]),
    do: {:error, format_reason(error)}

  defp expect_persist_job_results([_set, %Redix.Error{} = error]),
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
