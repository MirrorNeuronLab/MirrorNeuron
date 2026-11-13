defmodule MirrorNeuron.Persistence.RedisStore.Leases do
  @moduledoc "Ownership-checked leases and monotonic fencing epochs."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Values

  def acquire_lease(lease_name, owner_id, ttl_ms) do
    case Connection.command([
           "SET",
           Keys.key("lease", lease_name),
           owner_id,
           "PX",
           to_string(ttl_ms),
           "NX"
         ]) do
      {:ok, "OK"} -> :ok
      {:ok, nil} -> {:error, :locked}
      {:error, reason} -> {:error, Values.format_reason(reason)}
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

    case Connection.command([
           "EVAL",
           script,
           "1",
           Keys.key("lease", lease_name),
           owner_id,
           to_string(ttl_ms)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, Values.format_reason(reason)}
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

    case Connection.command(["EVAL", script, "1", Keys.key("lease", lease_name), owner_id]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def get_lease(lease_name) do
    case Connection.command(["GET", Keys.key("lease", lease_name)]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, owner_id} -> {:ok, owner_id}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def acquire_fenced_lease(lease_name, owner_id, ttl_ms) do
    lease_key = Keys.key("lease", lease_name)
    epoch_key = Keys.key("lease", lease_name, "epoch")

    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      local epoch = redis.call("incr", KEYS[2])
      redis.call("psetex", KEYS[1], ARGV[2], ARGV[1] .. "|" .. epoch)
      return {"ok", tostring(epoch)}
    else
      return {"locked", redis.call("get", KEYS[1])}
    end
    """

    case Connection.command([
           "EVAL",
           script,
           "2",
           lease_key,
           epoch_key,
           owner_id,
           to_string(ttl_ms)
         ]) do
      {:ok, ["ok", epoch]} ->
        {:ok, lease_payload(owner_id, epoch, ttl_ms)}

      {:ok, ["locked", value]} ->
        {:error, {:locked, parse_fenced_lease(value)}}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
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

    case Connection.command([
           "EVAL",
           script,
           "1",
           Keys.key("lease", lease_name),
           fenced_lease_value(owner_id, epoch),
           to_string(ttl_ms)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, Values.format_reason(reason)}
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

    case Connection.command([
           "EVAL",
           script,
           "1",
           Keys.key("lease", lease_name),
           fenced_lease_value(owner_id, epoch)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, Values.format_reason(reason)}
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

    case Connection.command([
           "EVAL",
           script,
           "2",
           Keys.key("lease", lease_name),
           Keys.key("lease", lease_name, "epoch"),
           fenced_lease_value(owner_id, epoch)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp lease_payload(owner_id, epoch, ttl_ms) do
    %{"owner_id" => owner_id, "epoch" => Values.parse_integer(epoch), "ttl_ms" => ttl_ms}
  end

  def fenced_lease_value(owner_id, epoch), do: "#{owner_id}|#{epoch}"

  defp parse_fenced_lease(nil), do: nil

  defp parse_fenced_lease(value) when is_binary(value) do
    case String.split(value, "|", parts: 2) do
      [owner_id, epoch] -> lease_payload(owner_id, epoch, nil)
      [owner_id] -> %{"owner_id" => owner_id, "epoch" => nil, "ttl_ms" => nil}
    end
  end

  defp parse_fenced_lease(value),
    do: %{"owner_id" => inspect(value), "epoch" => nil, "ttl_ms" => nil}
end
