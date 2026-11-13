defmodule MirrorNeuron.Persistence.RedisStore.DeploymentIndex do
  @moduledoc "Maintains deployment ownership indexes without removing live replacements."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  @deployments_set "deployments"

  def remove_stale_deployment_pointer(current_key, deployment_key, deployment_id) do
    script = """
    if redis.call("get", KEYS[2]) ~= ARGV[1] then
      return 0
    end

    local existing = redis.call("get", KEYS[1])

    if existing then
      local ok, decoded = pcall(cjson.decode, existing)

      if ok and type(decoded) == "table" and decoded["deployment_key"] == ARGV[2] then
        return 0
      end
    end

    redis.call("del", KEYS[2])
    redis.call("srem", KEYS[3], ARGV[1])
    return 1
    """

    deployments_key = Keys.key("deployment", "key", deployment_key, "deployments")

    case Connection.command([
           "EVAL",
           script,
           "3",
           Keys.key("deployment", deployment_id),
           current_key,
           deployments_key,
           deployment_id,
           deployment_key
         ]) do
      {:ok, _removed} -> :ok
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def purge_missing_deployment(deployment_id) do
    with {:ok, current_keys} <-
           Connection.scan_keys(Keys.key("deployment", "key", "*", "current")),
         {:ok, deployment_set_keys} <-
           Connection.scan_keys(Keys.key("deployment", "key", "*", "deployments")),
         {:ok, _result} <-
           purge_missing_deployment(deployment_id, current_keys, deployment_set_keys) do
      :ok
    end
  end

  def purge_missing_deployment(deployment_id, current_keys, deployment_set_keys) do
    script = """
    if redis.call("exists", KEYS[1]) ~= 0 then
      return 0
    end

    redis.call("srem", KEYS[2], ARGV[1])
    local current_count = tonumber(ARGV[2])

    for index = 3, 2 + current_count do
      if redis.call("get", KEYS[index]) == ARGV[1] then
        redis.call("del", KEYS[index])
      end
    end

    for index = 3 + current_count, #KEYS do
      redis.call("srem", KEYS[index], ARGV[1])
    end

    return 1
    """

    keys =
      [Keys.key("deployment", deployment_id), Keys.key(@deployments_set)] ++
        current_keys ++ deployment_set_keys

    case Connection.command([
           "EVAL",
           script,
           to_string(length(keys))
           | keys ++ [deployment_id, to_string(length(current_keys))]
         ]) do
      {:ok, result} when result in [0, 1] ->
        with :ok <- Connection.maybe_wait_for_deleted_keys(result), do: {:ok, result}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  def remove_missing_deployment_version(deployment_key, version) do
    version = to_string(version)
    version_key = Keys.key("deployment", "key", deployment_key, "version", version)
    versions_key = Keys.key("deployment", "key", deployment_key, "versions")

    case remove_missing_deployment_version(version_key, versions_key, version) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def remove_missing_deployment_version(version_key, versions_key, version) do
    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      redis.call("srem", KEYS[2], ARGV[1])
      return 1
    end

    return 0
    """

    case Connection.command([
           "EVAL",
           script,
           "2",
           version_key,
           versions_key,
           version
         ]) do
      {:ok, result} when result in [0, 1] ->
        with :ok <- Connection.maybe_wait_for_deleted_keys(result), do: {:ok, result}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  def sweep_deployment_indexes do
    with {:ok, current_keys} <-
           Connection.scan_keys(Keys.key("deployment", "key", "*", "current")),
         {:ok, deployment_set_keys} <-
           Connection.scan_keys(Keys.key("deployment", "key", "*", "deployments")),
         {:ok, deployment_ids} <-
           deployment_index_ids(current_keys, deployment_set_keys),
         {:ok, existence} <- deployment_existence(deployment_ids),
         :ok <- Results.expect_no_redis_errors(existence),
         stale_ids <- stale_deployment_ids(deployment_ids, existence),
         {:ok, removed_ids} <-
           purge_stale_deployments(stale_ids, current_keys, deployment_set_keys),
         {:ok, version_set_keys} <-
           Connection.scan_keys(Keys.key("deployment", "key", "*", "versions")),
         {:ok, removed_versions} <- sweep_missing_deployment_versions(version_set_keys) do
      removed_ids = Enum.sort(removed_ids)

      {:ok,
       %{
         stale_deployment_count: length(removed_ids),
         stale_deployments: removed_ids,
         stale_deployment_version_count: removed_versions
       }}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  defp deployment_index_ids(current_keys, deployment_set_keys) do
    set_keys = [Keys.key(@deployments_set) | deployment_set_keys]

    with {:ok, set_results} <- Connection.pipeline(Enum.map(set_keys, &["SMEMBERS", &1])),
         :ok <- Results.expect_no_redis_errors(set_results),
         {:ok, current_ids} <- deployment_current_ids(current_keys) do
      ids = set_results |> Enum.flat_map(& &1) |> Kernel.++(current_ids)
      {:ok, ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  defp deployment_current_ids([]), do: {:ok, []}

  defp deployment_current_ids(current_keys) do
    case Connection.command(["MGET" | current_keys]) do
      {:ok, deployment_ids} -> {:ok, Enum.reject(deployment_ids, &is_nil/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deployment_existence([]), do: {:ok, []}

  defp deployment_existence(deployment_ids) do
    Connection.pipeline(Enum.map(deployment_ids, &["EXISTS", Keys.key("deployment", &1)]))
  end

  defp stale_deployment_ids(deployment_ids, existence) do
    deployment_ids
    |> Enum.zip(existence)
    |> Enum.flat_map(fn
      {deployment_id, 0} -> [deployment_id]
      {_deployment_id, 1} -> []
    end)
  end

  defp purge_stale_deployments(deployment_ids, current_keys, deployment_set_keys) do
    Enum.reduce_while(deployment_ids, {:ok, []}, fn deployment_id, {:ok, removed} ->
      case purge_missing_deployment(deployment_id, current_keys, deployment_set_keys) do
        {:ok, 1} -> {:cont, {:ok, [deployment_id | removed]}}
        {:ok, 0} -> {:cont, {:ok, removed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      {:error, _reason} = error -> error
    end
  end

  defp sweep_missing_deployment_versions(version_set_keys) do
    Enum.reduce_while(version_set_keys, {:ok, 0}, fn versions_key, {:ok, removed} ->
      case Connection.command(["SMEMBERS", versions_key]) do
        {:ok, versions} ->
          case sweep_missing_deployment_versions(versions_key, versions) do
            {:ok, count} -> {:cont, {:ok, removed + count}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sweep_missing_deployment_versions(versions_key, versions) do
    Enum.reduce_while(versions, {:ok, 0}, fn version, {:ok, removed} ->
      version_key =
        String.replace_suffix(versions_key, ":versions", ":version:#{version}")

      case Connection.command(["EXISTS", version_key]) do
        {:ok, 1} ->
          {:cont, {:ok, removed}}

        {:ok, 0} ->
          case remove_missing_deployment_version(version_key, versions_key, version) do
            {:ok, result} -> {:cont, {:ok, removed + result}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, other}}
      end
    end)
  end
end
