defmodule MirrorNeuron.Persistence.RedisStore do
  @jobs_set "jobs"

  def persist_job(job_id, job_map) do
    with {:ok, "OK"} <- command(["SET", key("job", job_id), Jason.encode!(job_map)]),
         {:ok, _count} <- command(["SADD", key(@jobs_set), job_id]) do
      {:ok, job_map}
    end
  end

  def persist_terminal_job(job_id, updates, defaults \\ %{}) do
    existing =
      case fetch_job(job_id) do
        {:ok, job} when is_map(job) -> job
        _ -> %{}
      end

    job_map =
      defaults
      |> Map.merge(existing)
      |> Map.merge(updates)
      |> Map.put("job_id", job_id)
      |> Map.put_new("submitted_at", timestamp())
      |> Map.put("updated_at", timestamp())

    persist_job(job_id, job_map)
  end

  def fetch_job(job_id) do
    case command(["GET", key("job", job_id)]) do
      {:ok, nil} -> {:error, "job #{job_id} was not found"}
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def append_event(job_id, event) do
    encoded = Jason.encode!(event)

    with {:ok, _count} <- command(["RPUSH", key("job", job_id, "events"), encoded]),
         {:ok, _count} <- command(["PUBLISH", channel("events", job_id), encoded]) do
      {:ok, event}
    end
  end

  def read_events(job_id) do
    case command(["LRANGE", key("job", job_id, "events"), "0", "-1"]) do
      {:ok, items} -> {:ok, Enum.map(items, &Jason.decode!/1)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def persist_agent(job_id, agent_id, snapshot) do
    encoded = Jason.encode!(snapshot)

    with {:ok, "OK"} <- command(["SET", key("job", job_id, "agent", agent_id), encoded]),
         {:ok, _count} <- command(["SADD", key("job", job_id, "agents"), agent_id]) do
      {:ok, snapshot}
    end
  end

  def list_agents(job_id) do
    with {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]) do
      agents =
        agent_ids
        |> Enum.sort()
        |> Enum.map(fn agent_id ->
          {:ok, encoded} = command(["GET", key("job", job_id, "agent", agent_id)])
          Jason.decode!(encoded)
        end)

      {:ok, agents}
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def delete_job(job_id) do
    with {:ok, agent_ids} <- command(["SMEMBERS", key("job", job_id, "agents")]) do
      keys =
        [
          key("job", job_id),
          key("job", job_id, "events"),
          key("job", job_id, "agents")
        ] ++ Enum.map(agent_ids, &key("job", job_id, "agent", &1))

      _ = command(["DEL" | keys])
      _ = command(["SREM", key(@jobs_set), job_id])
      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  defp command(args), do: Redix.command(MirrorNeuron.Redis.Connection, args)

  defp key(part1), do: Enum.join([namespace(), part1], ":")
  defp key(part1, part2), do: Enum.join([namespace(), part1, part2], ":")
  defp key(part1, part2, part3), do: Enum.join([namespace(), part1, part2, part3], ":")

  defp key(part1, part2, part3, part4),
    do: Enum.join([namespace(), part1, part2, part3, part4], ":")

  defp channel(part1, part2), do: Enum.join([namespace(), "channel", part1, part2], ":")

  defp namespace, do: Application.get_env(:mirror_neuron, :redis_namespace, "mirror_neuron")

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
