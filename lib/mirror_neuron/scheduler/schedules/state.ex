defmodule MirrorNeuron.Scheduler.Schedules.State do
  @moduledoc "Serializes schedule mutations with revision checks and Redis fencing."

  require Logger

  alias MirrorNeuron.Scheduler.Schedules.Eligibility
  alias MirrorNeuron.Persistence.RedisStore

  @state_lease_ttl_ms 30_000
  @state_lease_wait_ms 35_000
  @state_lease_retry_ms 10

  def mutate_observed_schedule(observed, update) do
    fields = ~w(enabled status owner_node kind next_run_at crons run_at trigger missed_policy)

    with_schedule_state_lock(observed["schedule_id"], fn lock ->
      with {:ok, current} <- RedisStore.fetch_schedule(observed["schedule_id"]) do
        if Eligibility.schedule_owner?(current) and
             Map.take(current, fields) == Map.take(observed, fields) do
          mutate_schedule_with_lock(current["schedule_id"], lock, update)
        else
          {:ok, current}
        end
      end
    end)
  end

  def mutate_schedule(schedule_id, update) do
    with_schedule_state_lock(schedule_id, fn lock ->
      mutate_schedule_with_lock(schedule_id, lock, update)
    end)
  end

  def mutate_schedule_with_lock(schedule_id, lock, update) do
    with {:ok, current} <- RedisStore.fetch_schedule(schedule_id),
         {:ok, next_schedule} <- apply_schedule_update(update, current) do
      RedisStore.persist_schedule_fenced(
        schedule_id,
        next_schedule,
        lock.lease_name,
        lock.owner,
        lock.lease["epoch"]
      )
    end
  end

  defp apply_schedule_update(update, current) do
    case update.(current) do
      {:ok, next_schedule} when is_map(next_schedule) -> {:ok, next_schedule}
      {:error, _reason} = error -> error
      next_schedule when is_map(next_schedule) -> {:ok, next_schedule}
      other -> {:error, {:invalid_schedule_update, other}}
    end
  end

  def delete_schedule_locked(schedule_id, opts) do
    with_schedule_state_lock(schedule_id, fn lock ->
      with {:ok, current} <- RedisStore.fetch_schedule(schedule_id),
           :ok <- check_expected_revision(current, opts) do
        RedisStore.delete_schedule_fenced(
          schedule_id,
          lock.lease_name,
          lock.owner,
          lock.lease["epoch"]
        )
      end
    end)
  end

  def check_expected_revision(schedule, opts) do
    expected = Keyword.get(opts, :expected_revision, 0)

    if expected == 0 or expected == schedule["revision"],
      do: :ok,
      else: {:error, :revision_mismatch}
  end

  def with_schedule_state_lock(schedule_id, operation) do
    deadline = System.monotonic_time(:millisecond) + @state_lease_wait_ms
    with_schedule_state_lock(schedule_id, operation, deadline)
  end

  defp with_schedule_state_lock(schedule_id, operation, deadline) do
    case acquire_schedule_state_lock(schedule_id, deadline) do
      {:ok, lock} ->
        result =
          try do
            operation.(lock)
          after
            _ =
              RedisStore.release_fenced_lease(
                lock.lease_name,
                lock.owner,
                lock.lease["epoch"]
              )
          end

        if result == {:error, :not_owner} and before_deadline?(deadline) do
          with_schedule_state_lock(schedule_id, operation, deadline)
        else
          result
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp acquire_schedule_state_lock(schedule_id, deadline) do
    lease_name = "schedule:#{schedule_id}:state"
    owner = "#{Node.self()}:#{System.unique_integer([:positive, :monotonic])}"
    acquire_schedule_state_lock(schedule_id, lease_name, owner, deadline)
  end

  defp acquire_schedule_state_lock(schedule_id, lease_name, owner, deadline) do
    case RedisStore.acquire_fenced_lease(lease_name, owner, @state_lease_ttl_ms) do
      {:ok, lease} ->
        {:ok, %{lease_name: lease_name, owner: owner, lease: lease}}

      {:error, {:locked, _lease}} ->
        if before_deadline?(deadline) do
          Process.sleep(@state_lease_retry_ms)
          acquire_schedule_state_lock(schedule_id, lease_name, owner, deadline)
        else
          {:error, {:schedule_state_lock_timeout, schedule_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp before_deadline?(deadline), do: System.monotonic_time(:millisecond) < deadline

  def log_schedule_update_failure(_schedule_id, {:ok, _schedule}), do: :ok

  def log_schedule_update_failure(_schedule_id, :ok), do: :ok

  def log_schedule_update_failure(schedule_id, {:error, reason}) do
    Logger.error("failed to update schedule #{schedule_id}: #{inspect(reason)}")
    :ok
  end
end
