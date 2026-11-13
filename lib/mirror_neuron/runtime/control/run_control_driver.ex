defmodule MirrorNeuron.Runtime.RunControl.Driver do
  @moduledoc "One observer per run; journal claims prevent replay after transport/process loss."
  use GenServer, restart: :transient
  alias MirrorNeuron.Persistence.{RedisStore, RunControlStore}
  alias MirrorNeuron.Runtime.{EventBus, JobCalls, JobControl, RunLifecycle}

  def start_link(run_id),
    do:
      GenServer.start_link(__MODULE__, run_id,
        name: {:via, Registry, {MirrorNeuron.Runtime.RunControl.Registry, run_id}}
      )

  def init(run_id) do
    EventBus.subscribe(run_id)
    Process.send_after(self(), :tick, 1_000)
    {:ok, %{run_id: run_id, task: nil}, {:continue, :advance}}
  end

  def handle_continue(:advance, state), do: advance(state)

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)
    advance(state)
  end

  def handle_info(:advance, state), do: advance(state)
  def handle_info({:mirror_neuron_event, _}, state), do: advance(state)

  def handle_info({ref, result}, %{task: {ref, receipt}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:error, {:job_call_timeout, _, _}} -> :ok
      {:error, {:job_call_failed, _, _}} -> :ok
      {:error, {:job_not_running, _}} -> :ok
      {:queued_cancelled, :ok} -> complete(state, receipt)
      {:queued_cancelled, {:error, reason}} -> fail(state, receipt, error_code(reason))
      {:error, reason} -> fail(state, receipt, error_code(reason))
      _ -> :ok
    end

    advance(%{state | task: nil})
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: {ref, _}} = state),
    do: advance(%{state | task: nil})

  def handle_info(_, state), do: {:noreply, state}

  defp advance(%{task: task} = state) when not is_nil(task), do: {:noreply, state}

  defp advance(state) do
    with {:ok, receipts} <- RunControlStore.list(state.run_id),
         receipt when not is_nil(receipt) <-
           Enum.find(receipts, &(not RunControlStore.terminal?(&1))),
         {:ok, run} <- RedisStore.fetch_job(state.run_id) do
      progress(state, receipt, run)
    else
      nil ->
        RunControlStore.forget_pending(state.run_id)
        {:stop, :normal, state}

      {:error, :not_found} ->
        RunControlStore.forget_pending(state.run_id)
        {:stop, :normal, state}

      _ ->
        {:noreply, state}
    end
  end

  defp progress(state, %{"status" => "queued"} = receipt, run) do
    cond do
      expired?(receipt) ->
        fail_and_advance(state, receipt, "control_wait_expired")

      (run["status"] == "pending" and receipt["action"] != "cancel") or
          (receipt["action"] == "resume" and run["pause_cleanup_status"] == "pending") ->
        update_progress(state, receipt, %{"phase" => "waiting_for_previous_transition"})

        {:noreply, state}

      true ->
        dispatch(state, receipt)
    end
  end

  defp progress(state, receipt, run) do
    proof = run["run_control"] || %{}
    lifecycle = run["lifecycle"] || %{}
    matching = proof["request_id"] == receipt["request_id"]

    cond do
      matching and proof["error"] ->
        fail_and_advance(state, receipt, proof["error"])

      matching and receipt["action"] == "pause" and run["pause_cleanup_status"] == "complete" ->
        complete(state, receipt)

      matching and receipt["action"] == "pause" and run["pause_cleanup_status"] == "failed" ->
        fail_and_advance(state, receipt, "pause_cleanup_failed")

      matching and receipt["action"] == "resume" and run["status"] == "running" and
        lifecycle["generation"] == (proof["generation"] || receipt["request_id"]) and
          RunLifecycle.ready?(lifecycle) ->
        complete(state, receipt)

      matching and receipt["action"] == "cancel" and proof["cleanup"] == "complete" ->
        complete(state, receipt)

      run["status"] in ~w(failed completed cancelled) and
          not (matching and receipt["action"] == "cancel" and run["status"] == "cancelled") ->
        fail_and_advance(state, receipt, "run_terminated")

      matching and receipt["action"] == "resume" and run["recovery_requires_review"] == true ->
        fail_and_advance(state, receipt, "run_requires_review")

      matching and
          Enum.any?(lifecycle["services"] || %{}, fn {_, value} -> value["state"] == "failed" end) ->
        fail_and_advance(state, receipt, "service_readiness_failed")

      expired?(receipt) ->
        fail_and_advance(state, receipt, "control_wait_expired")

      not matching and System.system_time(:millisecond) - receipt["dispatched_at_ms"] > 30_000 ->
        fail_and_advance(state, receipt, "control_outcome_unconfirmed")

      true ->
        phase =
          if receipt["action"] == "resume",
            do: "waiting_for_readiness",
            else: "waiting_for_cleanup"

        waiting =
          Enum.reject(
            lifecycle["required"] || [],
            &(get_in(lifecycle, ["services", &1, "state"]) == "serving")
          )

        update_progress(state, receipt, %{"phase" => phase, "waiting_for" => waiting})

        {:noreply, state}
    end
  end

  defp update_progress(state, receipt, attrs) do
    unless Enum.all?(attrs, fn {key, value} -> receipt[key] == value end) do
      RunControlStore.update(state.run_id, receipt["request_id"], attrs)
    end
  end

  defp dispatch(state, receipt) do
    case RunControlStore.claim(state.run_id, receipt["request_id"]) do
      {:ok, %{"claimed" => true}} ->
        task =
          Task.Supervisor.async_nolink(MirrorNeuron.Runtime.RecoveryTaskSupervisor, fn ->
            execute(state.run_id, receipt)
          end)

        {:noreply, %{state | task: {task.ref, receipt}}}

      _ ->
        {:noreply, state}
    end
  end

  defp execute(run_id, %{"queued_only" => true, "action" => "cancel"}) do
    # Admission owns the atomic queued-only guard.
    {:queued_cancelled, MirrorNeuron.Runtime.NodeAdmission.cancel(run_id)}
  end

  defp execute(run_id, receipt) do
    action = %{"pause" => :pause, "resume" => :resume, "cancel" => :cancel}[receipt["action"]]

    case {action, RedisStore.fetch_job(run_id)} do
      {:cancel, {:ok, %{"status" => "queued"}}} ->
        {:queued_cancelled, MirrorNeuron.Runtime.NodeAdmission.cancel(run_id)}

      {:resume, _} ->
        JobControl.resume_controlled_job(run_id, receipt["request_id"])

      _ ->
        JobCalls.call_job(run_id, {:run_control, action, receipt["request_id"]})
    end
  end

  defp complete(state, receipt) do
    RunControlStore.update(state.run_id, receipt["request_id"], %{
      "status" => "completed",
      "phase" => "completed",
      "waiting_for" => []
    })

    send(self(), :advance)
    {:noreply, state}
  end

  defp fail_and_advance(state, receipt, code) do
    fail(state, receipt, code)
    send(self(), :advance)
    {:noreply, state}
  end

  defp fail(state, receipt, code),
    do:
      RunControlStore.update(state.run_id, receipt["request_id"], %{
        "status" => "failed",
        "phase" => "needs_review",
        "error" => %{"code" => code}
      })

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({code, _}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_), do: "control_failed"

  defp expired?(receipt),
    do: System.system_time(:millisecond) - receipt["created_at_ms"] > 1_800_000
end
