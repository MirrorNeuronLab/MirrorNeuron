defmodule Patch do
  def run do
    content = File.read!("lib/mirror_neuron/persistence/redis_store.ex")
    new_functions = """
  def acquire_lease(lease_name, owner_id, ttl_ms) do
    # SET name owner_id PX ttl_ms NX
    case command(["SET", key("lease", lease_name), owner_id, "PX", to_string(ttl_ms), "NX"]) do
      {:ok, "OK"} -> :ok
      {:ok, nil} -> {:error, :locked}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def renew_lease(lease_name, owner_id, ttl_ms) do
    script = \"\"\"
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("pexpire", KEYS[1], ARGV[2])
    else
      return 0
    end
    \"\"\"
    case command(["EVAL", script, "1", key("lease", lease_name), owner_id, to_string(ttl_ms)]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def release_lease(lease_name, owner_id) do
    script = \"\"\"
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
    \"\"\"
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
"""
    new_content = String.replace(content, "  defp command(args), do: command(args, 1)", new_functions <> "\n  defp command(args), do: command(args, 1)")
    File.write!("lib/mirror_neuron/persistence/redis_store.ex", new_content)
  end
end
Patch.run()
