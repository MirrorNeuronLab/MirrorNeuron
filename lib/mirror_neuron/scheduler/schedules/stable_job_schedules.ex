defmodule MirrorNeuron.Runtime.StableJob.Schedules do
  @moduledoc "Attaches, pauses and deletes schedules owned by a stable Job definition."

  alias MirrorNeuron.Runtime.StableJob.Queries
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob.StartGate

  def attach_schedule(job_id, schedule_id) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id) do
        updated =
          Map.update(definition, "schedule_ids", [schedule_id], &Enum.uniq(&1 ++ [schedule_id]))

        RedisStore.persist_job_definition(job_id, updated)
      end
    end)
  end

  def delete_job_schedules(job_id) do
    with {:ok, schedules} <- RedisStore.list_schedules() do
      schedules
      |> Enum.filter(&(&1["job_id"] == job_id))
      |> Enum.reduce_while(:ok, fn schedule, :ok ->
        case MirrorNeuron.Runtime.ScheduleDispatcher.delete_schedule(schedule["schedule_id"]) do
          :ok -> {:cont, :ok}
          {:ok, _schedule} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def pause_job_schedules(job_id) do
    with {:ok, schedules} <- RedisStore.list_schedules() do
      schedules
      |> Enum.filter(&(&1["job_id"] == job_id and &1["status"] != "paused"))
      |> Enum.reduce_while(:ok, fn schedule, :ok ->
        case MirrorNeuron.Runtime.ScheduleDispatcher.pause_schedule(schedule["schedule_id"]) do
          {:ok, _schedule} -> {:cont, :ok}
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
end
