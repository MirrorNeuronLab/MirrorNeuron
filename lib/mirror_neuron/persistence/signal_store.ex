defmodule MirrorNeuron.Persistence.SignalStore do
  @moduledoc "Bounded, sequenced response/error journals independent of data delivery quotas."
  alias MirrorNeuron.Persistence.RedisStore, as: Store
  alias MirrorNeuron.Persistence.ProtectedRedis
  @limit 5_000
  @ttl 604_800

  def append(run_id, channel, event, incident_id \\ "") when channel in ["errors", "responses"] do
    encoded = Jason.encode!(event)

    if byte_size(encoded) > 32_768,
      do: {:error, :signal_too_large},
      else: append_bounded(run_id, channel, encoded, incident_id)
  end

  defp append_bounded(run_id, channel, encoded, incident_id) do
    script = """
    local event = cjson.decode(ARGV[1])
    if ARGV[4] ~= '' then
      local prior = redis.call('hget', KEYS[3], ARGV[4])
      if not prior and redis.call('hlen', KEYS[3]) >= tonumber(ARGV[2]) then return {'full'} end
      if prior and ARGV[6] == 'responses' then
        local saved = cjson.decode(prior)
        if (saved.payload.revision or 0) >= (event.payload.revision or 0) then return {'coalesced', prior} end
        if saved.type == event.type then return {'coalesced', prior} end
      end
      if prior and ARGV[6] == 'errors' then
        prior = cjson.decode(prior)
        event.payload.first_occurrence = prior.payload.first_occurrence
        event.revision = (prior.revision or 1) + 1
        event.payload.first_occurred_at = prior.payload.first_occurred_at
        event.payload.count = prior.payload.count + (event.type == 'runtime.error_observed' and 1 or 0)
        if prior.type == event.type and tonumber(ARGV[5]) - prior.observed_ms < 1000 then
          prior.payload.count = event.payload.count
          prior.payload.last_occurred_at = event.payload.last_occurred_at
          prior.payload.error = event.payload.error
          prior.revision = event.revision
          redis.call('hset', KEYS[3], ARGV[4], cjson.encode(prior))
          return {'coalesced', cjson.encode(prior)}
        end
      end
    end
    event.sequence = tonumber(redis.call('get', KEYS[2]) or '0') + 1
    event.revision = event.revision or 1
    event.observed_ms = tonumber(ARGV[5])
    event.channel = ARGV[6]
    if ARGV[6] == 'errors' and not event.payload.first_occurrence then
      event.payload.first_occurrence = {event_id=event.event_id, sequence=event.sequence,
        occurred_at=event.payload.first_occurred_at, error=event.payload.error}
    end
    local encoded = cjson.encode(event)
    if string.len(encoded) > 65536 then return {'too_large'} end
    redis.call('incr', KEYS[2])
    redis.call('rpush', KEYS[1], encoded)
    redis.call('ltrim', KEYS[1], -tonumber(ARGV[2]), -1)
    if ARGV[4] ~= '' then redis.call('hset', KEYS[3], ARGV[4], encoded) end
    for i=1,3 do redis.call('expire', KEYS[i], ARGV[3]); redis.call('sadd', KEYS[4], KEYS[i]) end
    redis.call('expire', KEYS[4], ARGV[3])
    return {'stored', encoded}
    """

    with {:ok, [status, encoded]} <-
           ProtectedRedis.command(
             channel,
             ["EVAL", script, "4" | keys(run_id, channel)] ++
               [
                 encoded,
                 to_string(if(channel == "responses", do: 10_000, else: @limit)),
                 to_string(@ttl),
                 incident_id,
                 to_string(System.system_time(:millisecond)),
                 channel
               ]
           ),
         :ok <- ProtectedRedis.barrier(channel),
         {:ok, saved} <- Jason.decode(encoded) do
      {:ok, saved, status == "stored"}
    else
      {:ok, ["full"]} -> {:error, :signal_capacity_exhausted}
      {:ok, ["too_large"]} -> {:error, :signal_too_large}
      error -> error
    end
  end

  def read(run_id, channel, after_sequence)
      when channel in ["errors", "responses"] and is_integer(after_sequence) and
             after_sequence >= 0 do
    journal_keys = keys(run_id, channel)

    # Cursor, journal and resynchronization projection must share one snapshot.
    script =
      "return {redis.call('lrange', KEYS[1], 0, -1), redis.call('get', KEYS[2]), redis.call('hvals', KEYS[3])}"

    with {:ok, [values, sequence, incidents]} <-
           ProtectedRedis.command(channel, ["EVAL", script, "3" | Enum.take(journal_keys, 3)]),
         :ok <- ProtectedRedis.confirm_snapshot(channel) do
      events = Enum.map(values, &Jason.decode!/1)
      latest = if sequence, do: String.to_integer(sequence), else: 0
      first = List.first(events)

      cond do
        after_sequence > latest ->
          {:error, :signal_replay_gap}

        (after_sequence > 0 and first) && first["sequence"] > after_sequence + 1 ->
          {:error, :signal_replay_gap}

        after_sequence == 0 ->
          {:ok, incidents |> Enum.map(&Jason.decode!/1) |> Enum.sort_by(& &1["sequence"])}

        true ->
          {:ok, Enum.filter(events, &(&1["sequence"] > after_sequence))}
      end
    end
  rescue
    _ -> {:error, :invalid_signal_journal}
  end

  def read(_, _, _), do: {:error, :invalid_signal_cursor}

  defp keys(run_id, channel) do
    Enum.map(
      ["events", "sequence", "incidents"],
      &Store.storage_key(["job", run_id, "signals", channel, &1])
    ) ++
      [Store.storage_key(["job", run_id, "delivery_keys"])]
  end
end
