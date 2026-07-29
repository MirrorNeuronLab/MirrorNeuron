defmodule MirrorNeuron.Persistence.CancellationStore do
  @moduledoc false

  alias MirrorNeuron.Config

  @clearable_statuses ["pending", "acknowledged"]

  # The request, status transition, fencing epoch and lease revocation deliberately
  # live in one Redis script. A coordinator that retained the old lease can no
  # longer overwrite the cancelling record after this returns.
  def request(job_id, target_nodes, request_id \\ request_id())
      when is_binary(job_id) and is_list(target_nodes) do
    now = timestamp()

    cancellation = %{
      "job_id" => job_id,
      "request_id" => request_id,
      "target_nodes" => Enum.uniq(Enum.reject(target_nodes, &blank?/1)),
      "acknowledged_nodes" => [],
      "status" => "pending",
      "requested_at" => now,
      "updated_at" => now,
      "acknowledged_at" => nil
    }

    script = """
    local existing = redis.call("get", KEYS[3])
    if existing then
      return {"existing", existing}
    end

    local encoded_job = redis.call("get", KEYS[1])
    if not encoded_job then
      return {"missing", ""}
    end

    local job = cjson.decode(encoded_job)
    local cancellation = cjson.decode(ARGV[1])
    local job_epoch = tonumber(job["lease_epoch"]) or 0
    local existing_lease = job["lease"]
    local lease_epoch = 0
    if type(existing_lease) == "table" then
      lease_epoch = tonumber(existing_lease["epoch"]) or 0
    end
    local stored_epoch = tonumber(redis.call("get", KEYS[5])) or 0
    local epoch = math.max(job_epoch, lease_epoch, stored_epoch) + 1
    redis.call("set", KEYS[5], epoch)
    cancellation["fence_epoch"] = epoch
    cancellation["updated_at"] = ARGV[2]

    job["status"] = "cancelling"
    job["cancellation"] = cancellation
    job["cancellation_fence_epoch"] = epoch
    job["lease_epoch"] = epoch
    job["updated_at"] = ARGV[2]

    if type(existing_lease) == "table" then
      existing_lease["epoch"] = epoch
      existing_lease["owner_id"] = cjson.null
      job["lease"] = existing_lease
    end

    local encoded_cancellation = cjson.encode(cancellation)
    encoded_cancellation = string.gsub(
      encoded_cancellation,
      '"acknowledged_nodes":{}',
      '"acknowledged_nodes":[]'
    )
    local updated_job = cjson.encode(job)
    updated_job = string.gsub(
      updated_job,
      '"acknowledged_nodes":{}',
      '"acknowledged_nodes":[]'
    )
    redis.call("set", KEYS[1], updated_job)

    local encoded_summary = redis.call("get", KEYS[2])
    if encoded_summary then
      local summary = cjson.decode(encoded_summary)
      summary["status"] = "cancelling"
      summary["updated_at"] = ARGV[2]
      summary["cancellation_fence_epoch"] = epoch
      redis.call("set", KEYS[2], cjson.encode(summary))
    end

    local encoded_guard = redis.call("get", KEYS[7])
    local guard = encoded_guard and cjson.decode(encoded_guard) or {}
    guard["job_id"] = ARGV[3]
    guard["status"] = "cancelling"
    guard["lease_epoch"] = epoch
    guard["cancellation_fence_epoch"] = epoch
    guard["updated_at"] = ARGV[2]
    redis.call("set", KEYS[7], cjson.encode(guard))

    redis.call("set", KEYS[3], encoded_cancellation)
    redis.call("sadd", KEYS[4], ARGV[3])
    redis.call("del", KEYS[6])
    return {"created", encoded_cancellation}
    """

    case command([
           "EVAL",
           script,
           "7",
           job_key(job_id),
           job_summary_key(job_id),
           cancellation_key(job_id),
           cancellations_key(),
           lease_epoch_key(job_id),
           lease_key(job_id),
           job_guard_key(job_id),
           Jason.encode!(cancellation),
           now,
           job_id
         ]) do
      {:ok, ["created", encoded]} -> decode_result(:created, encoded)
      {:ok, ["existing", encoded]} -> decode_result(:existing, encoded)
      {:ok, ["missing", _]} -> {:error, "job #{job_id} was not found"}
      {:error, _reason} = error -> error
      other -> {:error, "unexpected cancellation request result: #{inspect(other)}"}
    end
  end

  def fetch(job_id) when is_binary(job_id) do
    case command(["GET", cancellation_key(job_id)]) do
      {:ok, nil} -> {:error, "cancellation for job #{job_id} was not found"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, _reason} = error -> error
    end
  end

  def mark_public_cleared(job_id) when is_binary(job_id) do
    now = timestamp()

    script = """
    local encoded_cancellation = redis.call("get", KEYS[1])
    if not encoded_cancellation then
      return {"missing_cancellation", ""}
    end

    local cancellation = cjson.decode(encoded_cancellation)
    if cancellation["status"] ~= "pending" and cancellation["status"] ~= "acknowledged" then
      return {"invalid_cancellation", encoded_cancellation}
    end

    local encoded_job = redis.call("get", KEYS[2])
    if not encoded_job then
      if cancellation["public_cleared_at"] then
        return {"existing", encoded_cancellation}
      end
      return {"missing_job", encoded_cancellation}
    end

    local job = cjson.decode(encoded_job)
    if job["status"] ~= "cancelling" and job["status"] ~= "cancelled" then
      return {"job_not_clearable", encoded_cancellation}
    end

    local encoded_guard = redis.call("get", KEYS[3])
    if not encoded_guard then
      return {"missing_fence", encoded_cancellation}
    end

    local guard = cjson.decode(encoded_guard)
    local cancellation_epoch = tonumber(cancellation["fence_epoch"])
    local guard_epoch = tonumber(guard["cancellation_fence_epoch"])
    local job_epoch = tonumber(job["cancellation_fence_epoch"])
    if not cancellation_epoch or guard_epoch ~= cancellation_epoch or job_epoch ~= cancellation_epoch then
      return {"missing_fence", encoded_cancellation}
    end

    cancellation["public_cleared_at"] = cancellation["public_cleared_at"] or ARGV[1]
    cancellation["updated_at"] = ARGV[1]
    local updated = cjson.encode(cancellation)
    redis.call("set", KEYS[1], updated)
    return {"marked", updated}
    """

    case command([
           "EVAL",
           script,
           "3",
           cancellation_key(job_id),
           job_key(job_id),
           job_guard_key(job_id),
           now
         ]) do
      {:ok, [status, encoded]} when status in ["marked", "existing"] ->
        decode_cancellation(encoded)

      {:ok, ["missing_cancellation", _]} ->
        {:error, "cancellation for job #{job_id} was not found"}

      {:ok, ["missing_job", _]} ->
        {:error, "job #{job_id} was not found"}

      {:ok, ["missing_fence", _]} ->
        {:error, {:cancellation_fence_missing, job_id}}

      {:ok, ["job_not_clearable", _]} ->
        {:error, {:job_is_not_terminal, job_id}}

      {:ok, ["invalid_cancellation", encoded]} ->
        with {:ok, cancellation} <- Jason.decode(encoded) do
          {:error, {:cancellation_not_clearable, cancellation["status"]}}
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, "unexpected public clear result: #{inspect(other)}"}
    end
  end

  def finalize_public_clear(job_id) when is_binary(job_id) do
    now = timestamp()

    script = """
    local encoded = redis.call("get", KEYS[1])
    if not encoded then
      return {"missing", ""}
    end

    local cancellation = cjson.decode(encoded)
    if redis.call("exists", KEYS[2]) == 0 and cancellation["status"] == "acknowledged" then
      redis.call("del", KEYS[3], KEYS[4])
      cancellation["fence_released_at"] = cancellation["fence_released_at"] or ARGV[1]
      cancellation["updated_at"] = ARGV[1]
      encoded = cjson.encode(cancellation)
      redis.call("set", KEYS[1], encoded)
      return {"released", encoded}
    end

    return {"preserved", encoded}
    """

    case command([
           "EVAL",
           script,
           "4",
           cancellation_key(job_id),
           job_key(job_id),
           job_guard_key(job_id),
           lease_epoch_key(job_id),
           now
         ]) do
      {:ok, [status, encoded]} when status in ["released", "preserved"] ->
        decode_cancellation(encoded)

      {:ok, ["missing", _]} ->
        {:error, "cancellation for job #{job_id} was not found"}

      {:error, _reason} = error ->
        error

      other ->
        {:error, "unexpected public clear finalization result: #{inspect(other)}"}
    end
  end

  def pending_nodes(%{"status" => "pending"} = cancellation) do
    targets = Map.get(cancellation, "target_nodes", [])
    acknowledged = MapSet.new(Map.get(cancellation, "acknowledged_nodes", []))
    Enum.reject(targets, &MapSet.member?(acknowledged, &1))
  end

  def pending_nodes(_cancellation), do: []

  def list_pending_for_node(node_name) when is_binary(node_name) do
    script = """
    local pending = {}
    local job_ids = redis.call("smembers", KEYS[1])

    for _, job_id in ipairs(job_ids) do
      local cancellation_key = ARGV[2] .. job_id .. ARGV[3]
      local encoded = redis.call("get", cancellation_key)

      if not encoded then
        redis.call("srem", KEYS[1], job_id)
      else
        local cancellation = cjson.decode(encoded)

        if cancellation["status"] ~= "pending" then
          redis.call("srem", KEYS[1], job_id)
        else
          local is_target = false
          local already_acknowledged = false

          for _, node in ipairs(cancellation["target_nodes"] or {}) do
            if node == ARGV[1] then is_target = true end
          end

          for _, node in ipairs(cancellation["acknowledged_nodes"] or {}) do
            if node == ARGV[1] then already_acknowledged = true end
          end

          if is_target and not already_acknowledged then
            table.insert(pending, encoded)
          end
        end
      end
    end

    return pending
    """

    with {:ok, encoded_cancellations} <-
           command([
             "EVAL",
             script,
             "1",
             cancellations_key(),
             node_name,
             key("job") <> ":",
             ":cancellation"
           ]) do
      Enum.reduce_while(encoded_cancellations, {:ok, []}, fn encoded, {:ok, cancellations} ->
        case Jason.decode(encoded) do
          {:ok, cancellation} -> {:cont, {:ok, [cancellation | cancellations]}}
          {:error, reason} -> {:halt, {:error, "invalid cancellation record: #{inspect(reason)}"}}
        end
      end)
      |> case do
        {:ok, cancellations} -> {:ok, Enum.reverse(cancellations)}
        {:error, _reason} = error -> error
      end
    end
  end

  def acknowledge(job_id, node_name) when is_binary(job_id) and is_binary(node_name) do
    now = timestamp()

    script = """
    local encoded = redis.call("get", KEYS[1])
    if not encoded then
      return {"missing", ""}
    end

    local cancellation = cjson.decode(encoded)
    local target_nodes = cancellation["target_nodes"] or {}
    local acknowledged = cancellation["acknowledged_nodes"] or {}
    local is_target = false
    local already_acknowledged = false

    for _, node in ipairs(target_nodes) do
      if node == ARGV[1] then is_target = true end
    end

    if not is_target then
      return {"not_target", cjson.encode(cancellation)}
    end

    for _, node in ipairs(acknowledged) do
      if node == ARGV[1] then already_acknowledged = true end
    end

    if not already_acknowledged then
      table.insert(acknowledged, ARGV[1])
    end

    cancellation["acknowledged_nodes"] = acknowledged
    cancellation["updated_at"] = ARGV[2]

    local complete = true
    for _, node in ipairs(target_nodes) do
      local found = false
      for _, ack in ipairs(acknowledged) do
        if ack == node then found = true end
      end
      if not found then complete = false end
    end

    if complete then
      cancellation["status"] = "acknowledged"
      cancellation["acknowledged_at"] = cancellation["acknowledged_at"] or ARGV[2]
      redis.call("srem", KEYS[4], ARGV[3])

      local encoded_job = redis.call("get", KEYS[2])
      if encoded_job then
        local job = cjson.decode(encoded_job)
        job["status"] = "cancelled"
        job["updated_at"] = ARGV[2]
        job["result"] = {reason = "cancelled by durable cluster cancellation"}
        job["cancellation"] = cancellation
        redis.call("set", KEYS[2], cjson.encode(job))
      end

      local encoded_summary = redis.call("get", KEYS[3])
      if encoded_summary then
        local summary = cjson.decode(encoded_summary)
        summary["status"] = "cancelled"
        summary["updated_at"] = ARGV[2]
        redis.call("set", KEYS[3], cjson.encode(summary))
      end

      if not encoded_job and cancellation["public_cleared_at"] then
        redis.call("del", KEYS[5], KEYS[6])
        cancellation["fence_released_at"] = cancellation["fence_released_at"] or ARGV[2]
      else
        local encoded_guard = redis.call("get", KEYS[5])
        if encoded_guard then
          local guard = cjson.decode(encoded_guard)
          guard["status"] = "cancelled"
          guard["updated_at"] = ARGV[2]
          redis.call("set", KEYS[5], cjson.encode(guard))
        end
      end
    end

    redis.call("set", KEYS[1], cjson.encode(cancellation))
    return {complete and "completed" or "pending", cjson.encode(cancellation)}
    """

    case command([
           "EVAL",
           script,
           "6",
           cancellation_key(job_id),
           job_key(job_id),
           job_summary_key(job_id),
           cancellations_key(),
           job_guard_key(job_id),
           lease_epoch_key(job_id),
           node_name,
           now,
           job_id
         ]) do
      {:ok, [status, encoded]} when status in ["completed", "pending", "not_target"] ->
        with {:ok, cancellation} <- Jason.decode(encoded) do
          {:ok, String.to_atom(status), cancellation}
        end

      {:ok, ["missing", _]} ->
        {:error, "cancellation for job #{job_id} was not found"}

      {:error, _reason} = error ->
        error

      other ->
        {:error, "unexpected cancellation acknowledgement result: #{inspect(other)}"}
    end
  end

  def pending?(job_id) do
    case fetch(job_id) do
      {:ok, %{"status" => "pending"}} -> true
      _ -> false
    end
  end

  def clearable?(job_id) do
    case fetch(job_id) do
      {:ok, %{"status" => status}} -> status in @clearable_statuses
      _ -> false
    end
  end

  def request_id,
    do: "cancel-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp decode_result(kind, encoded) do
    with {:ok, cancellation} <- decode_cancellation(encoded) do
      {:ok, kind, cancellation}
    end
  end

  defp decode_cancellation(encoded), do: Jason.decode(encoded)

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp command(args) do
    case Redix.command(MirrorNeuron.Redis.Connection, args) do
      {:error, reason} -> {:error, inspect(reason)}
      result -> result
    end
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp job_key(job_id), do: key("job", job_id)
  defp job_summary_key(job_id), do: key("job", job_id, "summary")
  defp job_guard_key(job_id), do: key("job", job_id, "guard")
  defp cancellation_key(job_id), do: key("job", job_id, "cancellation")
  defp cancellations_key, do: key("cancellations")
  defp lease_key(job_id), do: key("lease", "job:#{job_id}")
  defp lease_epoch_key(job_id), do: key("lease", "job:#{job_id}", "epoch")
  defp key(part1), do: Enum.join([namespace(), part1], ":")
  defp key(part1, part2), do: Enum.join([namespace(), part1, part2], ":")
  defp key(part1, part2, part3), do: Enum.join([namespace(), part1, part2, part3], ":")
  defp namespace, do: Config.string("MN_REDIS_NAMESPACE", :redis_namespace)

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
