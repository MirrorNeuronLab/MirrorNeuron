defmodule MirrorNeuron.Persistence.RedisStore.JobRetention do
  @moduledoc "Keeps active and retryable run state durable and expires terminal snapshots."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  def apply_job_retention(job_id, job_map) do
    status = Values.field(job_map, "status")

    cond do
      RetentionPolicy.retained_retry_state?(job_map) ->
        Enum.each(
          [
            Keys.key("job", job_id),
            Keys.key("job", job_id, "summary"),
            Keys.key("job", job_id, "guard"),
            Keys.key("job", job_id, "retry_checkpoint")
          ],
          &Connection.persist_key/1
        )

        RedisStore.expire_job_deliveries(job_id, 60 * 60)

      RetentionPolicy.terminal_status?(status) ->
        Connection.expire_key(
          Keys.key("job", job_id, "retry_checkpoint"),
          RetentionPolicy.terminal_job_ttl_seconds()
        )

        with :ok <- expire_terminal_job(job_id),
             do: RedisStore.expire_job_deliveries(job_id, 60 * 60)

      true ->
        persist_active_job(job_id)
    end
  end

  def apply_job_projection_retention(job_id, job_map) do
    if RetentionPolicy.retained_retry_state?(job_map) do
      Enum.each(
        [Keys.key("job", job_id, "summary"), Keys.key("job", job_id, "guard")],
        &Connection.persist_key/1
      )

      :ok
    else
      if RetentionPolicy.terminal_status?(Map.get(job_map, "status") || Map.get(job_map, :status)) do
        expire_terminal_job(job_id)
      else
        :ok
      end
    end
  end

  defp persist_active_job(job_id) do
    [
      Keys.key("job", job_id),
      Keys.key("job", job_id, "summary"),
      Keys.key("job", job_id, "guard"),
      Keys.key("job", job_id, "events"),
      Keys.key("job", job_id, "agents")
    ]
    |> Enum.each(&Connection.persist_key/1)

    :ok
  end

  defp expire_terminal_job(job_id) do
    ttl_seconds = RetentionPolicy.terminal_job_ttl_seconds()

    [
      Keys.key("job", job_id),
      Keys.key("job", job_id, "summary"),
      Keys.key("job", job_id, "guard"),
      Keys.key("job", job_id, "events"),
      Keys.key("job", job_id, "agents")
    ]
    |> Enum.each(&Connection.expire_key(&1, ttl_seconds))

    case Connection.command(["SMEMBERS", Keys.key("job", job_id, "agents")]) do
      {:ok, agent_ids} ->
        Enum.each(agent_ids, fn agent_id ->
          Connection.expire_key(
            Keys.key("job", job_id, "agent", agent_id),
            RetentionPolicy.agent_snapshot_ttl_seconds()
          )

          Connection.expire_key(
            Keys.key("job", job_id, "agent_summary", agent_id),
            RetentionPolicy.agent_snapshot_ttl_seconds()
          )
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end
end
