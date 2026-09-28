defmodule MirrorNeuron.Runtime.ScheduleOccurrence do
  @moduledoc false

  alias MirrorNeuron.Persistence.RedisStore

  # Reservations outlive both leases and run retention. Only the caller that
  # durably creates the reservation may start work. An ambiguous interrupted
  # start is reconciled by identity, never by submitting another execution.
  def run(schedule, metadata, lock, start, store \\ RedisStore) do
    token = metadata["dispatch_id"]

    record = %{
      "run_id" => "scheduled_" <> token,
      "dispatch_id" => token,
      "status" => "reserved"
    }

    with {:ok, disposition, reserved} <-
           store.reserve_schedule_occurrence(schedule["schedule_id"], token, record, lock),
         :ok <- validate_record(record, reserved) do
      case disposition do
        :new ->
          case start.(reserved["run_id"]) do
            {:ok, result} -> remember(store, schedule, token, reserved, result, lock)
            error -> error
          end

        :existing ->
          reconcile(store, schedule, token, reserved, lock)
      end
    end
  end

  defp validate_record(expected, stored) when is_map(stored) do
    if stored["run_id"] == expected["run_id"] and stored["dispatch_id"] == expected["dispatch_id"] and
         stored["status"] in ["reserved", "submitted"] do
      :ok
    else
      {:error, :invalid_schedule_occurrence}
    end
  end

  defp validate_record(_expected, _stored), do: {:error, :invalid_schedule_occurrence}

  defp reconcile(_store, _schedule, _token, %{"status" => "submitted"} = record, _lock) do
    {:ok,
     result(record["run_id"], record["run_status"] || "pending")
     |> Map.put(:submitted_at, record["submitted_at"])}
  end

  defp reconcile(store, schedule, token, record, lock) do
    case store.fetch_job(record["run_id"]) do
      {:ok, run} ->
        metadata = get_in(run, ["manifest", "metadata", "schedule_dispatch"])

        if is_map(metadata) and metadata["dispatch_id"] == token and
             metadata["schedule_id"] == schedule["schedule_id"] do
          remember(
            store,
            schedule,
            token,
            record,
            Map.put(result(record["run_id"], run["status"]), :submitted_at, run["submitted_at"]),
            lock
          )
        else
          {:error, :schedule_occurrence_identity_mismatch}
        end

      {:error, _reason} ->
        # Absence after an interrupted start is not proof that work never ran.
        # Keep the reservation for operator review instead of risking a duplicate.
        {:error, :schedule_occurrence_unconfirmed}
    end
  end

  defp remember(store, schedule, token, record, result, lock) do
    result =
      Map.put(
        result,
        :submitted_at,
        Map.get(result, :submitted_at) || DateTime.to_iso8601(DateTime.utc_now())
      )

    submitted =
      Map.merge(record, %{
        "status" => "submitted",
        "run_status" => result.status,
        "submitted_at" => result.submitted_at
      })

    with :ok <-
           store.complete_schedule_occurrence(schedule["schedule_id"], token, submitted, lock) do
      {:ok, result}
    end
  end

  defp result(run_id, status) do
    %{
      action: "started",
      run_id: run_id,
      status: status,
      pid: nil,
      replaced_run_ids: [],
      cleanup_deferred: false,
      cleanup_pending_nodes: []
    }
  end
end
