defmodule MirrorNeuron.Persistence.RedisStore.Deployments do
  @moduledoc "Deployment identities, immutable versions and discovery reads."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.DeploymentIndex
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.RuntimeStatus
  alias MirrorNeuron.Persistence.RedisStore.Values

  @deployments_set "deployments"
  @runtime_status_event_max_count 10_000

  def persist_deployment(deployment_id, deployment_map) do
    deployment =
      deployment_map
      |> Values.stringify_map()
      |> Map.put("deployment_id", deployment_id)
      |> Map.put_new("created_at", Values.timestamp())
      |> Map.put("updated_at", Values.timestamp())

    deployment_key = Map.get(deployment, "deployment_key")
    revision = RuntimeStatus.runtime_status_revision(deployment)

    script = """
    local existing = redis.call("get", KEYS[1])

    if existing then
      local ok, decoded = pcall(cjson.decode, existing)

      if not ok or type(decoded) ~= "table" or tostring(decoded["deployment_id"]) ~= ARGV[1] then
        return redis.error_reply("invalid existing deployment " .. ARGV[1])
      end

      local old_key = decoded["deployment_key"]

      if type(old_key) == "string" and old_key ~= "" and old_key ~= ARGV[3] then
        local old_current = ARGV[4] .. old_key .. ":current"

        if redis.call("get", old_current) == ARGV[1] then
          redis.call("del", old_current)
        end

        redis.call("srem", ARGV[4] .. old_key .. ":deployments", ARGV[1])
      end
    end

    redis.call("set", KEYS[1], ARGV[2])
    redis.call("sadd", KEYS[2], ARGV[1])

    if ARGV[3] ~= "" then
      redis.call("set", ARGV[4] .. ARGV[3] .. ":current", ARGV[1])
      redis.call("sadd", ARGV[4] .. ARGV[3] .. ":deployments", ARGV[1])
    end

    redis.call(
      "xadd", KEYS[3], "MAXLEN", "~", ARGV[7], "*",
      "node", ARGV[5], "domain", "deployments", "entity_id", ARGV[1],
      "action", "upsert", "revision", ARGV[6]
    )

    return 1
    """

    args = [
      "EVAL",
      script,
      "3",
      Keys.key("deployment", deployment_id),
      Keys.key(@deployments_set),
      RuntimeStatus.cluster_runtime_status_stream_key(),
      deployment_id,
      Jason.encode!(deployment),
      if(is_binary(deployment_key), do: deployment_key, else: ""),
      Keys.key("deployment", "key", ""),
      to_string(NodeAdapter.self()),
      revision,
      to_string(@runtime_status_event_max_count)
    ]

    case Connection.command(args) do
      {:ok, 1} ->
        with :ok <- Connection.wait_for_replicas(), do: {:ok, deployment}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  def fetch_deployment(deployment_id) do
    case Connection.command(["GET", Keys.key("deployment", deployment_id)]) do
      {:ok, nil} ->
        {:error, "deployment #{deployment_id} was not found"}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"deployment_id" => ^deployment_id} = deployment} -> {:ok, deployment}
          {:ok, deployment} when is_map(deployment) -> {:error, :invalid_deployment}
          {:ok, _invalid} -> {:error, :invalid_deployment}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def fetch_deployment_by_key(deployment_key) do
    current_key = Keys.key("deployment", "key", deployment_key, "current")

    case Connection.command(["GET", current_key]) do
      {:ok, nil} ->
        {:error, "deployment #{deployment_key} was not found"}

      {:ok, deployment_id} ->
        case fetch_deployment(deployment_id) do
          {:ok, %{"deployment_key" => ^deployment_key} = deployment} ->
            {:ok, deployment}

          {:ok, _mismatched} ->
            case DeploymentIndex.remove_stale_deployment_pointer(
                   current_key,
                   deployment_key,
                   deployment_id
                 ) do
              :ok -> {:error, "deployment #{deployment_key} was not found"}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            if missing_deployment?(deployment_id, reason) do
              case DeploymentIndex.purge_missing_deployment(deployment_id) do
                :ok -> {:error, "deployment #{deployment_key} was not found"}
                {:error, cleanup_reason} -> {:error, cleanup_reason}
              end
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def fetch_deployment_ref(id_or_key) do
    case fetch_deployment(id_or_key) do
      {:ok, deployment} ->
        {:ok, deployment}

      {:error, reason} ->
        if missing_deployment?(id_or_key, reason),
          do: fetch_deployment_by_key(id_or_key),
          else: {:error, reason}
    end
  end

  def list_deployments do
    with {:ok, deployment_ids} <- Connection.command(["SMEMBERS", Keys.key(@deployments_set)]) do
      fetch_indexed_deployments(deployment_ids)
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def persist_job_version(deployment_key, version, version_map) do
    version_id = to_string(version)

    version_record =
      version_map
      |> Values.stringify_map()
      |> Map.put("deployment_key", deployment_key)
      |> Map.put("version", version_id)
      |> Map.put_new("created_at", Values.timestamp())
      |> Map.put("updated_at", Values.timestamp())

    commands = [
      [
        "SET",
        Keys.key("deployment", "key", deployment_key, "version", version_id),
        Jason.encode!(version_record)
      ],
      ["SADD", Keys.key("deployment", "key", deployment_key, "versions"), version_id]
    ]

    with {:ok, results} <- Connection.transaction(commands),
         :ok <- Results.expect_first_result(results, fn value -> value == "OK" end),
         :ok <- Connection.wait_for_replicas() do
      {:ok, version_record}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def fetch_job_version(deployment_key, version) do
    version_id = to_string(version)

    case Connection.command([
           "GET",
           Keys.key("deployment", "key", deployment_key, "version", version_id)
         ]) do
      {:ok, nil} ->
        {:error, "deployment #{deployment_key} version #{version_id} was not found"}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"deployment_key" => ^deployment_key, "version" => ^version_id} = record} ->
            {:ok, record}

          {:ok, record} when is_map(record) ->
            {:error, :invalid_deployment_version}

          {:ok, _invalid} ->
            {:error, :invalid_deployment_version}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def list_job_versions(deployment_key) do
    with {:ok, versions} <-
           Connection.command([
             "SMEMBERS",
             Keys.key("deployment", "key", deployment_key, "versions")
           ]) do
      fetch_indexed_deployment_versions(deployment_key, versions)
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp fetch_indexed_deployments(deployment_ids) do
    deployment_ids
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn deployment_id, {:ok, deployments} ->
      case fetch_deployment(deployment_id) do
        {:ok, deployment} ->
          {:cont, {:ok, [deployment | deployments]}}

        {:error, reason} ->
          cond do
            missing_deployment?(deployment_id, reason) ->
              case DeploymentIndex.purge_missing_deployment(deployment_id) do
                :ok -> {:cont, {:ok, deployments}}
                {:error, cleanup_reason} -> {:halt, {:error, cleanup_reason}}
              end

            corrupt_deployment?(reason) ->
              Logger.debug("ignoring unreadable deployment #{deployment_id}: #{inspect(reason)}")
              {:cont, {:ok, deployments}}

            true ->
              {:halt, {:error, Values.format_reason(reason)}}
          end
      end
    end)
    |> case do
      {:ok, deployments} -> {:ok, Enum.reverse(deployments)}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_indexed_deployment_versions(deployment_key, versions) do
    versions
    |> Enum.sort_by(&version_sort_value/1)
    |> Enum.reduce_while({:ok, []}, fn version, {:ok, records} ->
      case fetch_job_version(deployment_key, version) do
        {:ok, record} ->
          {:cont, {:ok, [record | records]}}

        {:error, reason} ->
          cond do
            missing_deployment_version?(deployment_key, version, reason) ->
              case DeploymentIndex.remove_missing_deployment_version(deployment_key, version) do
                :ok -> {:cont, {:ok, records}}
                {:error, cleanup_reason} -> {:halt, {:error, cleanup_reason}}
              end

            corrupt_deployment_version?(reason) ->
              Logger.debug(
                "ignoring unreadable deployment #{deployment_key} version #{version}: #{inspect(reason)}"
              )

              {:cont, {:ok, records}}

            true ->
              {:halt, {:error, Values.format_reason(reason)}}
          end
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp version_sort_value(version) do
    case Integer.parse(to_string(version)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp missing_deployment?(deployment_id, reason),
    do: reason == "deployment #{deployment_id} was not found"

  defp missing_deployment_version?(deployment_key, version, reason),
    do: reason == "deployment #{deployment_key} version #{version} was not found"

  defp corrupt_deployment?(:invalid_deployment), do: true

  defp corrupt_deployment?(reason), do: Values.corrupt_json?(reason)

  defp corrupt_deployment_version?(:invalid_deployment_version), do: true

  defp corrupt_deployment_version?(reason), do: Values.corrupt_json?(reason)
end
