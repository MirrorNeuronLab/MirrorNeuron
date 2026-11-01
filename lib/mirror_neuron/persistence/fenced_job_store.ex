defmodule MirrorNeuron.Persistence.FencedJobStore do
  @moduledoc false

  # Keep the fence, job projection and optional terminal event in one Redis
  # transaction. A lost command response may safely replay this exact identity.
  @script ~S"""
  local prior = redis.call('GET', KEYS[3])
  if prior then
    prior = cjson.decode(prior)
    local incoming = tonumber(ARGV[5])
    local epoch = tonumber(prior.lease_epoch)
    if tonumber(prior.cancellation_fence_epoch) then return -2 end
    if epoch and (incoming < epoch) then return -1 end
    if ARGV[6] ~= '' and type(prior.finalization_id) == 'string' then
      if prior.finalization_id == ARGV[7] then return 0 end
      return -3
    end
  end
  if ARGV[1] ~= '' then redis.call('SET', KEYS[1], ARGV[1]) end
  redis.call('SET', KEYS[2], ARGV[2])
  redis.call('SET', KEYS[3], ARGV[3])
  local added = redis.call('SADD', KEYS[4], ARGV[4])
  if ARGV[6] ~= '' then
    redis.call('RPUSH', KEYS[5], ARGV[6])
    local maximum = tonumber(ARGV[8])
    if maximum > 0 then redis.call('LTRIM', KEYS[5], -maximum, -1) end
    local ttl = tonumber(ARGV[9])
    if ttl > 0 then redis.call('EXPIRE', KEYS[5], ttl) end
    redis.call('PUBLISH', ARGV[10], ARGV[6])
  end
  return added
  """

  def write(command, keys, args), do: command.(["EVAL", @script, "5" | keys ++ args])
end
