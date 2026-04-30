defmodule MirrorNeuron.Persistence.RedisStore do
  alias MirrorNeuron.Config
  alias MirrorNeuron.JobId

  @jobs_set "jobs"
  @terminal_statuses ["completed", "failed", "cancelled"]
  @default_terminal_job_ttl_seconds 7 * 24 * 60 * 60
  @default_event_ttl_seconds 7 * 24 * 60 * 60
  @default_event_max_count 10_000
  @default_agent_snapshot_ttl_seconds 7 * 24 * 60 * 60
  @default_bundle_archive_ttl_seconds 7 * 24 * 60 * 60

  def persist_job(job_id, job_map) do
    with :ok <- validate_job_lease_epoch(job_id, job_map),
         {:ok, "OK"} <- command(["SET", key("job", job_id), Jason.encode!(job_map)]),
         {:ok, _count} <- command(["SADD", key(@jobs_set), job_id]),
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
      jobs =
        job_ids
        |> Enum.map(fn job_id ->
          case fetch_job(job_id) do
            {:ok, job} -> job
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, jobs}
    end
  end

  def append_event(job_id, event) do
    encoded = Jason.encode!(event)

    with {:ok, _count} <- command(["RPUSH", key("job", job_id, "events"), encoded]),
         :ok <- trim_event_log(job_id),
         :ok <- expire_event_log(job_id),
         :ok <- wait_for_replicas(),
         {:ok, _count} <- command(["PUBLISH", channel("events", job_id), encoded]) do
      {:ok, event}
    end
  end

  def read_events(job_id, start \\ "0", stop \\ "-1") do
    case command(["LRANGE", key("job", job_id, "events"), to_string(start), to_string(stop)]) do
      {:ok, items} -> {:ok, Enum.map(items, &Jason.decode!/1)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_agent(job_id, agent_id, snapshot) do
    encoded = Jason.encode!(snapshot)

    with :ok <- validate_agent_lease_epoch(job_id, snapshot),
         {:ok, "OK"} <- command(["SET", key("job", job_id, "agent", agent_id), encoded]),
         {:ok, _count} <- command(["SADD", key("job", job_id, "agents"), agent_id]),
         :ok <- expire_agent_snapshot(job_id, agent_id),
         :ok <- wait_for_replicas() do
      {:ok, snapshot}
    end
  end

  def list_agents(job_id) do
    with {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]) do
      agents =
        agent_ids
        |> Enum.sort()
        |> Enum.map(fn agent_id ->
          case command(["GET", key("job", job_id, "agent", agent_id)]) do
            {:ok, nil} -> nil
            {:ok, encoded} -> Jason.decode!(encoded)
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, agents}
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

  def delete_job(job_id) do
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

    with {:ok, job_ids} <- list_job_ids() do
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
         stale_job_ids: stale_job_ids
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

  defp trim_event_log(job_id) do
    case event_max_count() do
      max_count when is_integer(max_count) and max_count > 0 ->
        case command(["LTRIM", key("job", job_id, "events"), "-#{max_count}", "-1"]) do
          {:ok, "OK"} -> :ok
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp expire_event_log(job_id) do
    expire_key(key("job", job_id, "events"), event_ttl_seconds())
  end

  defp expire_agent_snapshot(job_id, agent_id) do
    ttl_seconds = agent_snapshot_ttl_seconds()

    expire_key(key("job", job_id, "agent", agent_id), ttl_seconds)
    expire_key(key("job", job_id, "agents"), ttl_seconds)
  end

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
      "MIRROR_NEURON_TERMINAL_JOB_TTL_SECONDS",
      :terminal_job_ttl_seconds,
      @default_terminal_job_ttl_seconds
    )
  end

  defp event_ttl_seconds do
    config_integer(
      "MIRROR_NEURON_EVENT_TTL_SECONDS",
      :event_ttl_seconds,
      @default_event_ttl_seconds
    )
  end

  defp event_max_count do
    config_integer("MIRROR_NEURON_EVENT_MAX_COUNT", :event_max_count, @default_event_max_count)
  end

  defp agent_snapshot_ttl_seconds do
    config_integer(
      "MIRROR_NEURON_AGENT_SNAPSHOT_TTL_SECONDS",
      :agent_snapshot_ttl_seconds,
      @default_agent_snapshot_ttl_seconds
    )
  end

  defp bundle_archive_ttl_seconds do
    config_integer(
      "MIRROR_NEURON_BUNDLE_ARCHIVE_TTL_SECONDS",
      :bundle_archive_ttl_seconds,
      @default_bundle_archive_ttl_seconds
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

  defp command(args, attempts_left, backoff_ms) do
    case safe_command(MirrorNeuron.Redis.Connection, args) do
      {:error, reason} = error ->
        if attempts_left > 0 and reconnectable_error?(reason) do
          _ = MirrorNeuron.Redis.reconnect()
          Process.sleep(backoff_ms)

          case one_shot_command(args) do
            {:ok, _result} = ok ->
              ok

            {:error, retry_reason} = retry_error ->
              if reconnectable_error?(retry_reason) do
                command(args, attempts_left - 1, next_reconnect_backoff(backoff_ms))
              else
                retry_error
              end

            other ->
              other
          end
        else
          error
        end

      other ->
        other
    end
  end

  defp one_shot_command(args) do
    with {:ok, redis_url} <- redis_connection_url(),
         {:ok, conn} <- Redix.start_link(redis_url),
         result <- safe_command(conn, args) do
      GenServer.stop(conn, :normal, 1_000)
      result
    end
  end

  defp redis_connection_url do
    {:ok, MirrorNeuron.Redis.connection_url()}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

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

  defp reconnectable_error?(reason), do: MirrorNeuron.Redis.reconnectable_error?(reason)

  defp redis_reconnect_attempts do
    config_integer("MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS", :redis_reconnect_attempts, 10)
  end

  defp redis_reconnect_backoff_ms do
    config_integer("MIRROR_NEURON_REDIS_RECONNECT_BACKOFF_MS", :redis_reconnect_backoff_ms, 250)
  end

  defp redis_reconnect_max_backoff_ms do
    config_integer(
      "MIRROR_NEURON_REDIS_RECONNECT_MAX_BACKOFF_MS",
      :redis_reconnect_max_backoff_ms,
      2_000
    )
  end

  defp next_reconnect_backoff(backoff_ms) do
    min(backoff_ms * 2, redis_reconnect_max_backoff_ms())
  end

  defp wait_for_replicas do
    wait_replicas = config_integer("MIRROR_NEURON_REDIS_WAIT_REPLICAS", :redis_wait_replicas, 0)

    wait_timeout_ms =
      config_integer("MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms, 100)

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

  defp channel(part1, part2), do: Enum.join([namespace(), "channel", part1, part2], ":")

  defp namespace,
    do: Config.string("MIRROR_NEURON_REDIS_NAMESPACE", :redis_namespace)

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
