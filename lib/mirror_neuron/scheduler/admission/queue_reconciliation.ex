defmodule MirrorNeuron.Runtime.QueueReconciliation do
  @moduledoc false
  alias MirrorNeuron.Runtime.{JobCleanup, NativeRequestClaim, NodeAdmission, NodeAdmissionState}

  import MirrorNeuron.Runtime.AdmissionLedger,
    only: [entry: 1, snapshot: 0, mutate: 2, mutate: 3, store: 0]

  import MirrorNeuron.Runtime.NodeAdmission, only: [node_name: 0, gate_id: 1, wake: 0]
  @terminal ~w(completed failed cancelled)
  @active ~w(pending validated scheduled running paused pausing resuming cancelling)

  def import_existing, do: import_existing(5)
  defp import_existing(0), do: {:error, :node_admission_busy}

  defp import_existing(attempts) do
    case discover() do
      {:error, :admission_run_changed} -> import_existing(attempts - 1)
      result -> result
    end
  end

  defp discover do
    with {:ok, jobs} <- store().list_jobs(), {:ok, state} <- snapshot() do
      known =
        MapSet.new(
          Map.keys(state["reservations"]) ++
            Enum.map(state["queue"] ++ state["deferred"], & &1["run_id"])
        )

      jobs
      |> Enum.filter(
        &(local_run?(&1) and &1["status"] in ["queued" | @active] and
            not MapSet.member?(known, &1["job_id"]))
      )
      # Import existing consumers before considering capacity for waiting work.
      |> Enum.sort_by(&{&1["status"] == "queued", &1["submitted_at"], &1["job_id"]})
      |> Enum.reduce_while(:ok, fn job, :ok ->
        case repair(job["job_id"], job["status"] == "queued") do
          {:error, _} = err -> {:halt, err}
          _ -> {:cont, :ok}
        end
      end)
    end
  end

  defp repair(id, waiting?) do
    # Discovery is only a list of candidate IDs. Tie the actual decision
    # to the current canonical record, including its owner, at the Redis CAS.
    with {:ok, job, witness} <- store().fetch_admission_job(id),
         true <- local_run?(job) do
      case job["status"] do
        "queued" when waiting? ->
          with {:ok, attrs} <- entry(job), do: mutate("submit", attrs, witness)

        status when status in @active and not waiting? ->
          {:error, :missing_node_reservation}

        status when status in ["queued" | @active] ->
          {:error, :admission_run_changed}

        _ ->
          :ok
      end
    else
      false -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  def reconcile do
    with {:ok, state} <- snapshot() do
      Enum.each(state["requests"], fn {token, owner} ->
        if owner == "" do
          case MirrorNeuron.ModelServices.native_resource_command(%{
                 "operation" => "reconcile_request_lease",
                 "token" => token
               }) do
            {:ok, %{"status" => "drained"}} -> mutate("request_release", %{"token" => token})
            _ -> :ok
          end
        end
      end)

      Enum.each(Map.values(state["reservations"]), fn held ->
        unless NativeRequestClaim.native?(held), do: reconcile_holder(held)
      end)

      with :ok <- reconcile_schedules(state),
           :ok <- import_existing(),
           {:ok, reservations} <- mutate("promote", %{}) do
        reservations
        |> Enum.reject(&NativeRequestClaim.native?/1)
        |> Enum.each(&NodeAdmission.dispatch/1)

        :ok
      end
    end
  end

  defp reconcile_schedules(state) do
    # Include dangling projections after a crash between cancellation and
    # schedule deletion. The discovery list grants no authority to write.
    with {:ok, schedules} <- store().list_schedules() do
      ids =
        for s <- schedules,
            s["owner_node"] == node_name() and is_binary(s["target_run_id"]),
            do: s["target_run_id"]

      ids = Enum.uniq(ids ++ Enum.map(state["queue"] ++ state["deferred"], & &1["run_id"]))

      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case sync_schedule(id) do
          {:error, reason}
          when reason not in [:not_found, :admission_conflict, :admission_run_changed] ->
            {:halt, {:error, reason}}

          _ ->
            {:cont, :ok}
        end
      end)
    end
  end

  def sync_schedule(id), do: sync_schedule(id, 5)
  defp sync_schedule(_id, 0), do: {:error, :admission_conflict}

  defp sync_schedule(id, attempts) do
    result =
      with {:ok, job, witness} <- store().fetch_admission_job(id),
           {:ok, state} <- snapshot(),
           {:ok, saved} <- existing_schedule(id) do
        receipt = NodeAdmissionState.receipt(state, id)

        cond do
          saved && (saved["target_run_id"] != id or saved["owner_node"] != node_name()) ->
            {:error, :admission_run_changed}

          local_run?(job) and job["status"] == "queued" and receipt["state"] == "queued" ->
            attrs = schedule_attrs(job, receipt, saved)

            if saved && Map.take(saved, Map.keys(attrs)) == attrs,
              do: {:ok, saved},
              else:
                store().write_queue_schedule(node_name(), state["version"], witness, saved, attrs)

          receipt["state"] == "queued" and (job["status"] in @terminal or not local_run?(job)) ->
            with {:ok, _} <- mutate("cancel", %{"run_id" => id}, witness),
                 do: {:error, :admission_conflict}

          saved && (job["status"] != "queued" or not local_run?(job)) ->
            store().write_queue_schedule(node_name(), state["version"], witness, saved, nil)

          true ->
            {:ok, saved}
        end
      else
        {:error, :not_found} -> remove_orphan_schedule(id)
        error -> error
      end

    if result in [{:error, :admission_conflict}, {:error, :admission_run_changed}],
      do: sync_schedule(id, attempts - 1),
      else: result
  end

  defp remove_orphan_schedule(id) do
    with {:ok, state} <- snapshot(), {:ok, saved} <- existing_schedule(id) do
      if saved && saved["owner_node"] == node_name() && saved["target_run_id"] == id &&
           NodeAdmissionState.receipt(state, id)["state"] == "unreserved" do
        # The Run must still be missing at the write. A fresh submission or
        # owner recovery invalidates this observation.
        store().write_queue_schedule(node_name(), state["version"], {id, "missing"}, saved, nil)
      else
        {:ok, saved}
      end
    end
  end

  defp existing_schedule(id) do
    key = "queue_" <> id
    missing = "schedule #{key} was not found"

    case store().fetch_schedule(key) do
      {:error, reason} when reason in [:not_found, missing] -> {:ok, nil}
      other -> other
    end
  end

  defp schedule_attrs(job, receipt, saved) do
    %{
      "kind" => "resource_wait",
      "enabled" => true,
      "status" => "active",
      "target_run_id" => job["job_id"],
      "job_id" => job["stable_job_id"],
      "owner_node" => node_name(),
      "name" => job["job_name"],
      "not_before" => receipt["not_before"],
      "next_run_at" =>
        receipt["not_before"] || job["submitted_at"] || (saved || %{})["next_run_at"] ||
          MirrorNeuron.Runtime.timestamp(),
      "retry_interval_ms" => 5_000
    }
  end

  def local_run?(job), do: admission_owner(job) == node_name()

  defp admission_owner(job) do
    Enum.find(
      [
        get_in(job, ["admission", "owner_node"]),
        get_in(job, ["manifest", "metadata", "node_admission", "owner_node"])
      ],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp reconcile_holder(holder) do
    MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(holder["run_id"]), fn ->
      missing = "job #{holder["run_id"]} was not found"

      case store().fetch_job(holder["run_id"]) do
        {:ok, %{"status" => status} = job} when status in @terminal ->
          unless recovering?(job) do
            case JobCleanup.cleanup_sandboxes(holder["run_id"], job, []) do
              :ok -> release_stopped_holder(holder)
              _ -> mutate("cleanup_pending", Map.take(holder, ["run_id", "generation"]))
            end
          end

        {:error, reason} when reason == :not_found or reason == missing ->
          claim = Map.take(holder, ["run_id", "generation"])

          cond do
            holder["committed"] == false ->
              mutate("release", claim)

            cleared_cancellation_acknowledged?(holder["run_id"]) ->
              # Cancellation can finish after the operator deletes the public
              # run. The durable acknowledgment proves this node stopped its
              # workers. Active native request leases must also finish.
              release_stopped_holder(holder)

            true ->
              mutate("cleanup_pending", claim)
          end

        _ ->
          :ok
      end
    end)
  end

  defp release_stopped_holder(holder) do
    claim = Map.take(holder, ["run_id", "generation"])

    with :ok <- drain_terminal_requests(holder), {:ok, _} <- mutate("release", claim) do
      wake()
    else
      _ -> mutate("cleanup_pending", claim)
    end
  end

  defp cleared_cancellation_acknowledged?(run_id) do
    case store().fetch_cancellation(run_id) do
      {:ok,
       %{
         "status" => "acknowledged",
         "public_cleared_at" => cleared,
         "fence_epoch" => epoch,
         "acknowledged_nodes" => nodes
       }}
      when is_binary(cleared) and is_integer(epoch) and epoch > 0 and is_list(nodes) ->
        node_name() in nodes

      _ ->
        false
    end
  end

  # Workers have stopped and model unload/reference cleanup succeeded before this
  # proof is requested. A live native reader still prevents release. Lost tokens
  # after a native restart can be retired only at this terminal cleanup boundary.
  defp drain_terminal_requests(holder) do
    with {:ok, state} <- snapshot() do
      tokens = for {token, run} <- state["requests"], run == holder["run_id"], do: token

      if tokens == [] do
        :ok
      else
        with {:ok, %{"status" => "drained"}} <-
               MirrorNeuron.ModelServices.native_resource_command(%{
                 "operation" => "drain_terminal_requests",
                 "run_id" => holder["run_id"],
                 "tokens" => tokens
               }) do
          Enum.reduce_while(tokens, :ok, fn token, :ok ->
            case mutate("request_release", %{"token" => token}) do
              {:ok, _} -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
      end
    end
  end

  defp recovering?(job) do
    job["status"] == "failed" and
      (job["recovery_hint"] == "runner_interruption" or
         (get_in(job, ["result", "agent_id"]) == "job_runner" and
            get_in(job, ["result", "error"]) == "job coordinator exited before terminal state"))
  end
end
