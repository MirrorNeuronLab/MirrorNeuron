defmodule MirrorNeuron.Persistence.InteractionStore do
  @moduledoc false
  alias MirrorNeuron.Config
  # State and the replay event are committed by the same Redis transaction.
  # Replays are at-least-once; a response receipt is committed only once.
  @transaction ~S"""
  local id, op = ARGV[1], ARGV[2]
  local now = tonumber(ARGV[3])
  local input = cjson.decode(ARGV[4])
  local raw = redis.call('HGET', KEYS[1], id)
  local r = raw and cjson.decode(raw) or nil
  if op == 'create' and input.scope.session_id and input.kind ~= 'session' then
    local session = redis.call('HGET', KEYS[1], input.scope.session_id)
    if not session then return cjson.encode({error='session_closed'}) end
    session = cjson.decode(session)
    if session.state ~= 'pending' or session.expires_at <= now then return cjson.encode({error='session_closed'}) end
  end
  local function emit(record)
    local seq = redis.call('INCR', KEYS[3])
    record.updated_at = now
    redis.call('HSET', KEYS[1], id, cjson.encode(record))
    if record.state == 'pending' and record.expires_at and record.expires_at ~= cjson.null then
      redis.call('ZADD', KEYS[4], record.expires_at, id)
    else redis.call('ZREM', KEYS[4], id) end
    if record.state ~= 'pending' or record.kind == 'display' then
      redis.call('ZADD', KEYS[5], now + 604800000, id)
    end
    redis.call('XADD', KEYS[2], 'MAXLEN', '=', 10000, tostring(seq)..'-0', 'record', cjson.encode(record))
    return cjson.encode({record=record, cursor=tostring(seq)..'-0'})
  end
  if op == 'create' then
    if r then
      if r.creation_digest == input.creation_digest then return cjson.encode({record=r}) end
      return cjson.encode({error='identity_conflict'})
    end
    if redis.call('HLEN', KEYS[1]) >= 5000 then return cjson.encode({error='capacity_exceeded'}) end
    return emit(input)
  end
  if not r then return cjson.encode({error='not_found'}) end
  local cid = input.command_id
  if r.receipt and r.receipt.command_id == cid then
    if r.receipt.digest ~= input.digest then return cjson.encode({error='idempotency_conflict'}) end
    return cjson.encode({record=r})
  end
  if op == 'expire' then
    if r.state == 'pending' and r.expires_at and r.expires_at ~= cjson.null and r.expires_at <= now then
      r.state = 'expired'; r.revision = r.revision + 1; return emit(r)
    end
    return cjson.encode({record=r})
  end
  if (op == 'respond' or op == 'acknowledge') and r.scope.session_id then
    local session = redis.call('HGET', KEYS[1], r.scope.session_id)
    if not session then return cjson.encode({error='session_closed'}) end
    session = cjson.decode(session)
    if session.state ~= 'pending' or session.expires_at <= now then return cjson.encode({error='session_closed'}) end
  end
  if r.state == 'pending' and r.expires_at and r.expires_at ~= cjson.null and r.expires_at <= now then
    r.state = 'expired'; r.revision = r.revision + 1; emit(r)
    return cjson.encode({error='expired', changed=true})
  end
  if r.revision ~= input.expected_revision then return cjson.encode({error='revision_conflict'}) end
  if op == 'respond' or op == 'acknowledge' then
    if r.state ~= 'pending' then return cjson.encode({error='closed'}) end
    r.state = 'responded'
    r.receipt = {command_id=cid, digest=input.digest, answer=input.answer or {}, received_at=now}
  elseif op == 'cancel' then
    if r.state ~= 'pending' then return cjson.encode({error='closed'}) end
    r.state = 'cancelled'
  elseif op == 'effect' then
    if r.state ~= 'responded' and r.kind ~= 'display' then return cjson.encode({error='not_responded'}) end
    if r.effect == 'applied' or r.effect == 'failed' then return cjson.encode({error='effect_closed'}) end
    r.effect = input.effect
  elseif op == 'update' then
    if r.state ~= 'pending' then return cjson.encode({error='closed'}) end
    r.presentation = input.presentation
  else return cjson.encode({error='invalid_command'}) end
  r.revision = r.revision + 1
  return emit(r)
  """
  @snapshot ~S"""
  return {redis.call('GET', KEYS[2]) or '0', redis.call('HVALS', KEYS[1])}
  """

  def create(record) do
    digest = record |> Map.drop(~w(created_at updated_at)) |> digest()
    transact(record["id"], "create", Map.put(record, "creation_digest", digest))
  end

  def transition(op, record, command),
    do: transact(record["id"], op, Map.put(command, "digest", digest(command)))

  def get(id) do
    case command(["HGET", key("records"), id]) do
      {:ok, nil} ->
        {:error, "not_found"}

      {:ok, raw} ->
        record = raw |> Jason.decode!() |> decode_record()

        if record["state"] == "pending" and is_integer(record["expires_at"]) and
             record["expires_at"] <= System.system_time(:millisecond),
           do: transact(id, "expire", %{}),
           else: {:ok, record}

      {:error, _} ->
        {:error, "store_unavailable"}
    end
  end

  def snapshot do
    expire_due()

    case command(["EVAL", @snapshot, "2", key("records"), key("sequence")]) do
      {:ok, [sequence, records]} ->
        {:ok,
         %{
           "cursor" => sequence <> "-0",
           "items" => Enum.map(records, &(&1 |> Jason.decode!() |> decode_record())),
           "capability" => "mn.interaction.v1"
         }}

      {:error, _} ->
        {:error, "store_unavailable"}
    end
  end

  def events(cursor) do
    with {:ok, first} <- command(["XRANGE", key("events"), "-", "+", "COUNT", "1"]),
         :ok <- valid_cursor(cursor, first),
         {:ok, rows} <- command(["XRANGE", key("events"), "(" <> cursor, "+", "COUNT", "200"]) do
      {:ok,
       Enum.map(rows, fn [id, ["record", raw]] ->
         %{
           "id" => id,
           "type" => "interaction.updated",
           "data" => raw |> Jason.decode!() |> decode_record()
         }
       end)}
    else
      {:error, "cursor_expired"} = error -> error
      _ -> {:error, "store_unavailable"}
    end
  end

  def expire_due do
    now = to_string(System.system_time(:millisecond))

    case command(["ZRANGEBYSCORE", key("deadlines"), "-inf", now, "LIMIT", "0", "128"]) do
      {:ok, ids} -> Enum.each(ids, &transact(&1, "expire", %{}))
      _ -> :ok
    end

    case command(["ZRANGEBYSCORE", key("retention"), "-inf", now, "LIMIT", "0", "128"]) do
      {:ok, ids} ->
        Enum.each(ids, fn id ->
          command(["HDEL", key("records"), id])
          command(["ZREM", key("retention"), id])
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp valid_cursor(_, []), do: :ok

  defp valid_cursor(cursor, [[first, _]]) do
    if sequence(cursor) < sequence(first) - 1, do: {:error, "cursor_expired"}, else: :ok
  end

  defp sequence(cursor), do: cursor |> String.split("-") |> hd() |> String.to_integer()

  defp transact(id, op, input) do
    result =
      command([
        "EVAL",
        @transaction,
        "5",
        key("records"),
        key("events"),
        key("sequence"),
        key("deadlines"),
        key("retention"),
        id,
        op,
        to_string(System.system_time(:millisecond)),
        Jason.encode!(input)
      ])

    case result do
      {:ok, raw} ->
        case Jason.decode!(raw) do
          %{"error" => error, "changed" => true} ->
            notify()
            {:error, error}

          %{"error" => error} ->
            {:error, error}

          %{"record" => record, "cursor" => _} ->
            notify()
            {:ok, decode_record(record)}

          %{"record" => record} ->
            {:ok, decode_record(record)}
        end

      {:error, _} ->
        {:error, "store_unavailable"}
    end
  end

  # Redis Lua cjson encodes empty tables as objects, including JSON arrays.
  # Restore the declared list fields at every storage boundary; arbitrary
  # objects (scope, metadata, evidence and receipt answers) retain their types.
  defp decode_record(record) do
    record
    |> Map.update("options", [], &decode_list/1)
    |> Map.update("fields", [], &decode_fields/1)
    |> Map.update!("presentation", fn presentation ->
      presentation |> decode_optional_list("items") |> decode_optional_list("sources")
    end)
  end

  defp decode_fields(fields) do
    case decode_list(fields) do
      fields when is_list(fields) -> Enum.map(fields, &decode_optional_list(&1, "options"))
      other -> other
    end
  end

  defp decode_optional_list(value, key) do
    if Map.has_key?(value, key), do: Map.update!(value, key, &decode_list/1), else: value
  end

  defp decode_list(value) when value == %{}, do: []
  defp decode_list(value), do: value

  defp notify do
    Registry.dispatch(MirrorNeuron.Runtime.EventRegistry, :interactions, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, :interaction_changed) end)
    end)
  end

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp key(part),
    do: Config.string("MN_REDIS_NAMESPACE", :redis_namespace) <> ":interactions:" <> part

  defp command(args), do: Redix.command(MirrorNeuron.Redis.Connection, args)
end
