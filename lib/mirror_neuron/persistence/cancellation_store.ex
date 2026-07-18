defmodule MirrorNeuron.Persistence.CancellationStore do
  @moduledoc false

  alias MirrorNeuron.Config

  @active_statuses ["pending", "acknowledged"]

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
    local epoch = redis.call("incr", KEYS[5])
    cancellation["fence_epoch"] = epoch
    cancellation["updated_at"] = ARGV[2]

    job["status"] = "cancelling"
    job["cancellation"] = cancellation
    job["cancellation_fence_epoch"] = epoch
    job["lease_epoch"] = epoch
    job["updated_at"] = ARGV[2]

    local existing_lease = job["lease"]
    if type(existing_lease) == "table" then
      existing_lease["epoch"] = epoch
      existing_lease["owner_id"] = cjson.null
      job["lease"] = existing_lease
    end

    local encoded_cancellation = cjson.encode(cancellation)
    redis.call("set", KEYS[1], cjson.encode(job))

    local encoded_summary = redis.call("get", KEYS[2])
    if encoded_summary then
      local summary = cjson.decode(encoded_summary)
      summary["status"] = "cancelling"
      summary["updated_at"] = ARGV[2]
      summary["cancellation_fence_epoch"] = epoch
      redis.call("set", KEYS[2], cjson.encode(summary))
    end

    redis.call("set", KEYS[3], encoded_cancellation)
    redis.call("sadd", KEYS[4], ARGV[3])
    redis.call("del", KEYS[6])
    return {"created", encoded_cancellation}
    """

    case command([
           "EVAL",
           script,
           "6",
           job_key(job_id),
           job_summary_key(job_id),
           cancellation_key(job_id),
           cancellations_key(),
           lease_epoch_key(job_id),
           lease_key(job_id),
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

  def list_pending_for_node(node_name) when is_binary(node_name) do
    with {:ok, job_ids} <- command(["SMEMBERS", cancellations_key()]) do
      job_ids
      |> Enum.reduce([], fn job_id, cancellations ->
        case fetch(job_id) do
          {:ok, cancellation} ->
            if pending_for_node?(cancellation, node_name),
              do: [cancellation | cancellations],
              else: cancellations

          _ ->
            cancellations
        end
      end)
      |> Enum.reverse()
      |> then(&{:ok, &1})
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
      cancellation["acknowledged_at"] = ARGV[2]

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
    end

    redis.call("set", KEYS[1], cjson.encode(cancellation))
    return {complete and "completed" or "pending", cjson.encode(cancellation)}
    """

    case command([
           "EVAL",
           script,
           "3",
           cancellation_key(job_id),
           job_key(job_id),
           job_summary_key(job_id),
           node_name,
           now
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
      {:ok, %{"status" => status}} -> status in @active_statuses
      _ -> false
    end
  end

  def request_id,
    do: "cancel-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp decode_result(kind, encoded) do
    with {:ok, cancellation} <- Jason.decode(encoded) do
      {:ok, kind, cancellation}
    end
  end

  defp pending_for_node?(cancellation, node_name) do
    Map.get(cancellation, "status") == "pending" and
      node_name in Map.get(cancellation, "target_nodes", []) and
      node_name not in Map.get(cancellation, "acknowledged_nodes", [])
  end

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
