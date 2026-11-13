defmodule MirrorNeuron.Monitor.Actions do
  @moduledoc "Runs explicitly requested terminal cleanup and dead-letter replay."

  alias MirrorNeuron.Persistence.CancellationStore
  alias MirrorNeuron.Monitor.Queries
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  def clear_jobs() do
    with {:ok, all_jobs} <- Queries.list_jobs(include_terminal: true, summary: :basic),
         {:ok, pending_clear_job_ids} <- CancellationStore.list_pending_public_clear_job_ids() do
      to_delete =
        all_jobs
        |> Enum.filter(&(&1["status"] in ["completed", "failed", "cancelled"]))
        |> Enum.map(& &1["job_id"])
        |> Kernel.++(pending_clear_job_ids)
        |> Enum.uniq()

      deleted_count =
        Enum.count(to_delete, fn job_id ->
          match?({:ok, _result}, Runtime.clear_job_with_result(job_id))
        end)

      {:ok, deleted_count}
    end
  end

  def dead_letters(job_id) do
    with {:ok, events} <- RedisStore.read_events(job_id) do
      {:ok, Enum.filter(events, &(&1["type"] == "dead_letter"))}
    end
  end

  def replay_dead_letter(job_id, index) when is_integer(index) and index >= 0 do
    with {:ok, dead_letters} <- dead_letters(job_id),
         {:ok, event} <- Enum.fetch(dead_letters, index),
         agent_id when is_binary(agent_id) <- Map.get(event, "agent_id"),
         message when is_map(message) <- Map.get(event, "message"),
         {:ok, "delivered"} <- MirrorNeuron.send_message(job_id, agent_id, message) do
      {:ok, %{"replayed" => true, "job_id" => job_id, "agent_id" => agent_id, "index" => index}}
    else
      :error -> {:error, "dead letter index #{index} was not found"}
      nil -> {:error, "dead letter is missing agent_id or message"}
      {:error, reason} -> {:error, reason}
      other -> {:error, "failed to replay dead letter: #{inspect(other)}"}
    end
  end
end
