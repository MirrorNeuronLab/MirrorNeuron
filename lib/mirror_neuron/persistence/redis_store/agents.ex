defmodule MirrorNeuron.Persistence.RedisStore.Agents do
  @moduledoc "Compacted agent observations and lease-validated snapshot writes."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Guards
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  @doc false
  def persist_agent(job_id, agent_id, snapshot), do: persist_agent(job_id, agent_id, snapshot, [])

  @doc false
  def persist_agent(job_id, agent_id, snapshot, opts) when is_list(opts) do
    snapshot = agent_monitor_record(snapshot)
    encoded = Jason.encode!(snapshot)
    encoded_summary = Jason.encode!(snapshot)
    job_guard_result = Guards.fetch_job_guard(job_id)

    with :ok <- Guards.validate_agent_lease_epoch(snapshot, job_guard_result),
         retention_commands <-
           agent_snapshot_retention_commands(job_id, agent_id, job_guard_result),
         {:ok, results} <-
           Connection.transaction([
             ["SET", Keys.key("job", job_id, "agent", agent_id), encoded],
             ["SET", Keys.key("job", job_id, "agent_summary", agent_id), encoded_summary],
             ["SADD", Keys.key("job", job_id, "agents"), agent_id]
             | retention_commands
           ]),
         :ok <- Results.expect_persist_agent_results(results),
         :ok <- Connection.wait_for_replicas() do
      {:ok, snapshot}
    end
  end

  def list_agents(job_id) do
    with {:ok, agent_ids} <- Connection.command(["SMEMBERS", Keys.key("job", job_id, "agents")]) do
      fetch_agents(job_id, Enum.sort(agent_ids))
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def list_agent_summaries(job_id) do
    with {:ok, agent_ids} <- Connection.command(["SMEMBERS", Keys.key("job", job_id, "agents")]) do
      fetch_agent_summaries(job_id, Enum.sort(agent_ids))
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def fetch_agent(job_id, agent_id) do
    case Connection.command(["GET", Keys.key("job", job_id, "agent", agent_id)]) do
      {:ok, nil} -> {:error, "agent #{agent_id} was not found for job #{job_id}"}
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp fetch_agents(_job_id, []), do: {:ok, []}

  defp fetch_agents(job_id, agent_ids) do
    keys = Enum.map(agent_ids, &Keys.key("job", job_id, "agent", &1))

    case Connection.command(["MGET" | keys]) do
      {:ok, encoded_agents} -> {:ok, Values.decode_json_items(encoded_agents)}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp fetch_agent_summaries(_job_id, []), do: {:ok, []}

  defp fetch_agent_summaries(job_id, agent_ids) do
    keys = Enum.map(agent_ids, &Keys.key("job", job_id, "agent_summary", &1))

    with {:ok, encoded_summaries} <- Connection.command(["MGET" | keys]),
         {summaries, _missing_ids} <- decode_agent_summaries(agent_ids, encoded_summaries) do
      {:ok, Enum.flat_map(agent_ids, &List.wrap(Map.get(summaries, &1)))}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp decode_agent_summaries(agent_ids, encoded_summaries) do
    agent_ids
    |> Enum.zip(encoded_summaries)
    |> Enum.reduce({%{}, []}, fn
      {agent_id, encoded}, {summaries, missing_ids} when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, summary} when is_map(summary) ->
            {Map.put(summaries, agent_id, summary), missing_ids}

          _ ->
            {summaries, [agent_id | missing_ids]}
        end

      {agent_id, _encoded}, {summaries, missing_ids} ->
        {summaries, [agent_id | missing_ids]}
    end)
    |> then(fn {summaries, missing_ids} -> {summaries, Enum.reverse(missing_ids)} end)
  end

  defp expire_agent_snapshot_commands(job_id, agent_id) do
    ttl_seconds = RetentionPolicy.agent_snapshot_ttl_seconds()

    RetentionPolicy.maybe_expire_key_command(
      Keys.key("job", job_id, "agent", agent_id),
      ttl_seconds
    ) ++
      RetentionPolicy.maybe_expire_key_command(
        Keys.key("job", job_id, "agent_summary", agent_id),
        ttl_seconds
      ) ++
      RetentionPolicy.maybe_expire_key_command(Keys.key("job", job_id, "agents"), ttl_seconds)
  end

  defp agent_snapshot_retention_commands(job_id, agent_id, job_guard_result) do
    case job_guard_result do
      {:ok, job} ->
        if RetentionPolicy.terminal_status?(Map.get(job, "status")) do
          expire_agent_snapshot_commands(job_id, agent_id)
        else
          [
            ["PERSIST", Keys.key("job", job_id, "agent", agent_id)],
            ["PERSIST", Keys.key("job", job_id, "agents")]
          ]
        end

      {:error, _reason} ->
        expire_agent_snapshot_commands(job_id, agent_id)
    end
  end

  defp agent_monitor_record(snapshot) do
    snapshot = Values.stringify_map(snapshot)
    metadata = Map.get(snapshot, "metadata") || %{}

    %{
      "agent_id" => Map.get(snapshot, "agent_id"),
      "node_id" => Map.get(snapshot, "node_id"),
      "agent_type" => Map.get(snapshot, "agent_type"),
      "type" => Map.get(snapshot, "type"),
      "role" => Map.get(snapshot, "role"),
      "assigned_node" => Map.get(snapshot, "assigned_node"),
      "parent_job_id" => Map.get(snapshot, "parent_job_id"),
      "processed_messages" => Map.get(snapshot, "processed_messages", 0),
      "mailbox_depth" => Map.get(snapshot, "mailbox_depth", 0),
      "last_heartbeat_at" => Map.get(snapshot, "last_heartbeat_at"),
      "last_error" => compact_agent_error(Map.get(snapshot, "last_error")),
      "sandbox" => Map.get(snapshot, "sandbox"),
      "lease" => Map.get(snapshot, "lease") || %{},
      "metadata" => %{
        "paused" => Map.get(metadata, "paused", false),
        "backpressure" => Map.get(metadata, "backpressure") || %{},
        "lease_epoch" => Map.get(metadata, "lease_epoch") || Map.get(snapshot, "lease_epoch"),
        "lease_owner" => Map.get(metadata, "lease_owner") || Map.get(snapshot, "lease_owner"),
        "pending_message_count" => Map.get(metadata, "pending_message_count", 0),
        "execution_profile" => Map.get(metadata, "execution_profile")
      }
    }
  end

  defp compact_agent_error(error) when is_binary(error) and byte_size(error) > 8_192,
    do: binary_part(error, 0, 8_192)

  defp compact_agent_error(error), do: error
end
