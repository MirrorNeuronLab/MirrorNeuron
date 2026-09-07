defmodule MirrorNeuron.Runtime.ContextMemory do
  @moduledoc "Run-scoped lifecycle for Membrane's attached durable working index."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.RedisEnvironment

  def prefix(job_id, run_id) do
    if Enum.all?([job_id, run_id], &valid_id?/1) do
      {:ok,
       "mn:context:working:v1:{#{byte_size(job_id)}:#{job_id}:#{byte_size(run_id)}:#{run_id}}:"}
    else
      {:error, :invalid_context_scope}
    end
  end

  def cancel_run(run_id) do
    case RedisStore.fetch_job(run_id) do
      {:ok, job} -> apply_to_run(run_id, job, :cancel)
      {:error, _} -> :ok
    end
  end

  def clear_run(run_id, job), do: apply_to_run(run_id, job, :clear)

  defp apply_to_run(run_id, job, operation) when is_map(job) do
    manifest = job["manifest"] || %{}

    if manifest["required_context_engine"] == true do
      stable_id = job["stable_job_id"] || get_in(manifest, ["metadata", "job_id"]) || run_id

      with {:ok, scope} <- prefix(stable_id, run_id),
           url when is_binary(url) <- RedisEnvironment.agent_env()["MN_CONTEXT_REDIS_URL"],
           {:ok, connection} <- Redix.start_link(url, sync_connect: true, timeout: 5_000) do
        try do
          command = &Redix.command(connection, &1, timeout: 10_000)
          if operation == :cancel, do: fence(scope, command), else: clear(scope, command)
        after
          GenServer.stop(connection)
        end
      else
        _ -> {:error, :context_memory_backing_service_unavailable}
      end
    else
      :ok
    end
  catch
    :exit, _ -> {:error, :context_memory_backing_service_unavailable}
  end

  defp apply_to_run(_run_id, _job, _operation), do: :ok

  @doc false
  def fence(scope, command) do
    case command.(["SET", scope <> "cancelled", "1"]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :context_memory_fence_failed}
    end
  end

  @doc false
  def clear(scope, command) do
    # Retain the small tombstone: stale workers cannot recreate deleted memory.
    with :ok <- fence(scope, command), do: clear_page(scope, "0", command)
  end

  defp clear_page(scope, cursor, command) do
    with {:ok, [next, keys]} <- command.(["SCAN", cursor, "MATCH", scope <> "*", "COUNT", "128"]),
         keys <- Enum.reject(keys, &(&1 == scope <> "cancelled")),
         :ok <- unlink(keys, command) do
      if next == "0", do: :ok, else: clear_page(scope, next, command)
    else
      _ -> {:error, :context_memory_cleanup_failed}
    end
  end

  defp unlink([], _command), do: :ok

  defp unlink(keys, command) do
    keys
    |> Enum.chunk_every(128)
    |> Enum.reduce_while(:ok, fn page, :ok ->
      case command.(["UNLINK" | page]) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :context_memory_cleanup_failed}}
      end
    end)
  end

  defp valid_id?(value) when is_binary(value),
    do: byte_size(value) in 1..160 and Regex.match?(~r/\A[A-Za-z0-9_\-.@\/]+\z/, value)

  defp valid_id?(_), do: false
end
