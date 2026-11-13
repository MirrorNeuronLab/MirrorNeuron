defmodule MirrorNeuron.Persistence.RunControlStore do
  @moduledoc "Atomic, bounded per-run control journal. No credentials or command payloads."
  alias MirrorNeuron.Persistence.{ProtectedRedis, RedisStore}
  @terminal ~w(completed failed superseded)

  def terminal?(receipt), do: receipt["status"] in @terminal

  def enqueue(run_id, action, request_id, queued_only) do
    receipt = %{
      "request_id" => request_id,
      "run_id" => run_id,
      "action" => action,
      "queued_only" => queued_only,
      "status" => "queued",
      "phase" => "queued",
      "created_at_ms" => System.system_time(:millisecond),
      "updated_at" => MirrorNeuron.Runtime.timestamp()
    }

    script = """
    local raw = redis.call('GET', KEYS[1])
    local doc = raw and cjson.decode(raw) or {receipts={}}
    local item = cjson.decode(ARGV[1])
    local saved = redis.call('GET', KEYS[3])
    if saved then
      local old = cjson.decode(saved)
      if old.action ~= item.action or old.queued_only ~= item.queued_only then return {'conflict'} end
      return {'ok', saved}
    end
    local pending = 0
    for _, old in ipairs(doc.receipts) do
      if old.request_id == item.request_id then
        if old.action ~= item.action or old.queued_only ~= item.queued_only then return {'conflict'} end
        return {'ok', cjson.encode(old)}
      end
      if old.status == 'queued' or old.status == 'executing' then pending = pending + 1 end
    end
    if pending >= 16 and item.action ~= 'cancel' then return {'full'} end
    if #doc.receipts >= 128 then
      if doc.receipts[1].status == 'queued' or doc.receipts[1].status == 'executing' then return {'full'} end
      local old = table.remove(doc.receipts, 1)
      local old_key = KEYS[1] .. ':receipt:' .. old.request_id
      redis.call('SET', old_key, cjson.encode(old), 'EX', 604800)
      redis.call('SADD', KEYS[4], old_key)
    end
    if item.action == 'cancel' then
      for _, old in ipairs(doc.receipts) do
        if old.status == 'queued' or old.status == 'executing' then
          old.status = 'superseded'; old.phase = 'superseded'; old.superseded_by = item.request_id
        end
      end
    end
    table.insert(doc.receipts, item)
    redis.call('SET', KEYS[1], cjson.encode(doc))
    redis.call('SADD', KEYS[2], ARGV[2])
    redis.call('SADD', KEYS[4], KEYS[1])
    return {'ok', cjson.encode(item)}
    """

    eval(
      script,
      [
        key(run_id),
        pending_key(),
        receipt_key(run_id, request_id),
        RedisStore.storage_key(["job", run_id, "delivery_keys"])
      ],
      [Jason.encode!(receipt), run_id]
    )
  end

  def list(run_id) do
    case ProtectedRedis.command("controls", ["GET", key(run_id)]) do
      {:ok, nil} -> {:ok, []}
      {:ok, value} -> with {:ok, doc} <- Jason.decode(value), do: {:ok, doc["receipts"]}
      error -> error
    end
  end

  def get(run_id, id) do
    with {:ok, receipts} <- list(run_id) do
      case Enum.find(receipts, &(&1["request_id"] == id)) do
        nil ->
          case ProtectedRedis.command("controls", ["GET", receipt_key(run_id, id)]) do
            {:ok, nil} -> {:error, :not_found}
            {:ok, value} -> Jason.decode(value)
            error -> error
          end

        receipt ->
          {:ok, receipt}
      end
    end
  end

  def update(run_id, id, attrs) do
    script = """
    local raw = redis.call('GET', KEYS[1])
    if not raw then return {'missing'} end
    local doc = cjson.decode(raw)
    local terminal = {completed=true, failed=true, superseded=true}
    local result = nil
    local pending = false
    for _, item in ipairs(doc.receipts) do
      if item.request_id == ARGV[1] then
        if not terminal[item.status] then
          for k,v in pairs(cjson.decode(ARGV[2])) do item[k] = v end
        end
        result = item
      end
      if not terminal[item.status] then pending = true end
    end
    if not result then return {'missing'} end
    redis.call('SET', KEYS[1], cjson.encode(doc))
    if not pending then
      redis.call('SREM', KEYS[2], ARGV[3])
      redis.call('EXPIRE', KEYS[1], 604800)
    end
    return {'ok', cjson.encode(result)}
    """

    attrs = Map.put(attrs, "updated_at", MirrorNeuron.Runtime.timestamp())
    eval(script, [key(run_id), pending_key()], [id, Jason.encode!(attrs), run_id])
  end

  def forget_pending(run_id) do
    script = """
    local raw = redis.call('GET', KEYS[1])
    if raw then
      for _, item in ipairs(cjson.decode(raw).receipts) do
        if item.status == 'queued' or item.status == 'executing' then return 0 end
      end
    end
    return redis.call('SREM', KEYS[2], ARGV[1])
    """

    ProtectedRedis.command("controls", ["EVAL", script, "2", key(run_id), pending_key(), run_id])
  end

  def pending, do: ProtectedRedis.command("controls", ["SMEMBERS", pending_key()])

  def claim(run_id, id) do
    script = """
    local raw = redis.call('GET', KEYS[1])
    if not raw then return {'missing'} end
    local doc = cjson.decode(raw)
    for _, item in ipairs(doc.receipts) do
      if item.status == 'queued' or item.status == 'executing' then
        if item.request_id ~= ARGV[1] or item.status ~= 'queued' then return {'ok', '{"claimed":false}'} end
        item.status = 'executing'; item.phase = 'dispatching'; item.dispatched_at_ms = tonumber(ARGV[2])
        redis.call('SET', KEYS[1], cjson.encode(doc))
        return {'ok', '{"claimed":true}'}
      end
    end
    return {'ok', '{"claimed":false}'}
    """

    eval(script, [key(run_id)], [id, to_string(System.system_time(:millisecond))])
  end

  defp eval(script, keys, args) do
    case ProtectedRedis.command(
           "controls",
           ["EVAL", script, to_string(length(keys))] ++ keys ++ args
         ) do
      {:ok, ["ok", value]} ->
        with :ok <- ProtectedRedis.barrier("controls"), do: Jason.decode(value)

      {:ok, [reason]} ->
        {:error, {:run_control, reason}}

      error ->
        error
    end
  end

  defp receipt_key(run, id), do: key(run) <> ":receipt:" <> id
  defp key(run), do: RedisStore.storage_key(["job", run, "run_controls"])
  defp pending_key, do: RedisStore.storage_key(["run_controls", "pending"])
end
