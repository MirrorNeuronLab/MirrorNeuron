defmodule MirrorNeuron.Persistence.RedisStore.Admission do
  @moduledoc "Compare-and-swap resource admission and queue schedule projections."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Schedules
  alias MirrorNeuron.Persistence.RedisStore.Values

  def fetch_node_admission(node_name) do
    case Connection.command(["GET", Keys.key("node-admission", node_name)]) do
      {:ok, nil} -> {:ok, MirrorNeuron.Runtime.NodeAdmissionState.new()}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  # The exact bytes are a private CAS witness. Never re-encode the decoded
  # record: older writers need not serialize fields in the same order.

  def fetch_admission_job(id) do
    case Connection.command(["GET", Keys.key("job", id)]) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, bytes} ->
        with {:ok, job} <- Jason.decode(bytes), do: {:ok, job, {id, bytes}}

      error ->
        error
    end
  end

  def compare_node_admission(node, version, next, witness \\ nil) do
    admission_write(node, version, witness, nil, [
      ["SET", Keys.key("node-admission", node), Jason.encode!(next)]
    ])
  end

  def write_queue_schedule(node, version, {run_id, _} = witness, existing, attrs) do
    id = "queue_" <> run_id
    schedule = if attrs, do: Schedules.prepare_schedule(id, Map.merge(existing || %{}, attrs))

    commands =
      if schedule,
        do: Schedules.schedule_commands(id, schedule),
        else: Schedules.delete_schedule_commands(id)

    with :ok <- admission_write(node, version, witness, {id, existing}, commands),
         do: {:ok, schedule}
  end

  defp admission_write(node, version, witness, projection, commands) do
    script = """
    local prior = redis.call('GET', KEYS[1])
    if (prior and cjson.decode(prior)['version'] or 0) ~= tonumber(ARGV[1]) then return 0 end
    if ARGV[2] ~= '' then
      local job = redis.call('GET', KEYS[2])
      if ARGV[2] == 'missing' and job then return -1 end
      if ARGV[2] ~= 'missing' and job ~= ARGV[2] then return -1 end
    end
    if ARGV[3] ~= '' then
      local saved = redis.call('GET', KEYS[3])
      if ARGV[3] == 'missing' then
        if saved then return 0 end
      else
        if not saved then return 0 end
        local record = cjson.decode(saved)
        if (record['revision'] or 0) ~= tonumber(ARGV[3]) or record['target_run_id'] ~= ARGV[5]
          or record['owner_node'] ~= ARGV[6] then return 0 end
      end
    end
    for _, cmd in ipairs(cjson.decode(ARGV[4])) do redis.call(unpack(cmd)) end
    return 1
    """

    {id, bytes} = witness || {"", ""}
    {schedule_id, expected} = projection || {"", nil}

    revision =
      cond do
        projection == nil -> ""
        expected == nil -> "missing"
        true -> to_string(expected["revision"] || 0)
      end

    case Connection.command([
           "EVAL",
           script,
           "3",
           Keys.key("node-admission", node),
           Keys.key("job", id),
           Keys.key("schedule", schedule_id),
           to_string(version),
           bytes,
           revision,
           Jason.encode!(commands),
           id,
           node
         ]) do
      {:ok, 1} -> Connection.wait_for_replicas()
      {:ok, 0} -> {:error, :admission_conflict}
      {:ok, -1} -> {:error, :admission_run_changed}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def fetch_resource_limits do
    case Connection.command(["GET", Keys.key("resource", "limits")]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def persist_resource_limits(limits) when is_map(limits) do
    limits = Values.stringify_map(limits)

    with {:ok, "OK"} <-
           Connection.command(["SET", Keys.key("resource", "limits"), Jason.encode!(limits)]),
         :ok <- Connection.wait_for_replicas() do
      {:ok, limits}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end
end
