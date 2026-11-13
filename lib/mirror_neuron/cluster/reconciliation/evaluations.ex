defmodule MirrorNeuron.Cluster.Reconciler.Evaluations do
  @moduledoc "Queues, starts and finalizes durable recovery evaluations."

  alias MirrorNeuron.Cluster.Reconciler.EvaluationRecords
  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Cluster.Reconciler.Recovery
  alias MirrorNeuron.Cluster.Reconciler.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Cluster.Reconciler.Timing

  @eval_retry_statuses ["pending", "blocked"]

  def enqueue_and_process_eval(job, trigger, failed_node, affected_agents, reason, opts) do
    trigger = to_string(trigger)

    case EvaluationRecords.find_active_eval(job["job_id"], trigger, failed_node, opts) do
      %{"status" => "running"} = eval ->
        Results.skipped(job, "recovery eval #{eval["eval_id"]} is already running")

      %{"status" => "blocked"} = eval ->
        if Timing.due_eval?(eval) or Keyword.get(opts, :force, false) do
          eval
          |> Map.put("status", "pending")
          |> Map.put("updated_at", Runtime.timestamp())
          |> EvaluationRecords.persist_recovery_eval(opts)
          |> case do
            {:ok, persisted} ->
              maybe_process_eval(persisted, opts)

            {:error, persist_reason} ->
              Results.failed(job, "could not persist recovery eval: #{inspect(persist_reason)}")
          end
        else
          Results.blocked(job, Map.get(eval, "block_reason") || reason, %{
            eval_id: eval["eval_id"],
            wait_until: Map.get(eval, "wait_until"),
            failed_node: failed_node,
            affected_agents: affected_agents
          })
        end

      existing when is_map(existing) ->
        eval =
          existing
          |> Map.merge(%{
            "trigger" => trigger,
            "reason" => reason,
            "failed_node" => failed_node,
            "affected_agents" => affected_agents,
            "status" => "pending",
            "updated_at" => Runtime.timestamp()
          })

        with {:ok, persisted} <- EvaluationRecords.persist_recovery_eval(eval, opts) do
          maybe_process_eval(persisted, opts)
        else
          {:error, persist_reason} ->
            Results.failed(job, "could not persist recovery eval: #{inspect(persist_reason)}")
        end

      nil ->
        eval =
          EvaluationRecords.new_recovery_eval(job, trigger, failed_node, affected_agents, reason)

        with {:ok, persisted} <- EvaluationRecords.persist_recovery_eval(eval, opts) do
          maybe_process_eval(persisted, opts)
        else
          {:error, persist_reason} ->
            Results.failed(job, "could not persist recovery eval: #{inspect(persist_reason)}")
        end
    end
  end

  defp maybe_process_eval(eval, opts) do
    if Keyword.get(opts, :defer, false) do
      Results.skipped(EvaluationRecords.eval_job(eval), "queued recovery eval #{eval["eval_id"]}")
    else
      process_recovery_eval(eval, opts)
    end
  end

  def process_recovery_eval(%{"status" => status} = eval, opts)
      when status in @eval_retry_statuses do
    if Timing.due_eval?(eval) or Keyword.get(opts, :force, false) do
      do_process_recovery_eval(eval, opts)
    else
      Results.blocked(
        EvaluationRecords.eval_job(eval),
        Map.get(eval, "block_reason") || "recovery eval is waiting",
        %{
          eval_id: eval["eval_id"],
          wait_until: Map.get(eval, "wait_until"),
          failed_node: Map.get(eval, "failed_node"),
          affected_agents: Map.get(eval, "affected_agents", [])
        }
      )
    end
  end

  def process_recovery_eval(eval, _opts) do
    Results.skipped(
      EvaluationRecords.eval_job(eval),
      "recovery eval #{eval["eval_id"]} is #{eval["status"]}"
    )
  end

  defp do_process_recovery_eval(eval, opts) do
    attempt = Timing.recovery_eval_attempt(eval) + 1
    running_at = Runtime.timestamp()

    running_eval =
      eval
      |> Map.put("status", "running")
      |> Map.put("attempt", attempt)
      |> Map.put("started_at", running_at)
      |> Map.put("updated_at", running_at)
      |> Map.put(
        "history",
        EvaluationRecords.append_eval_history(eval, "running", "attempt #{attempt} started")
      )

    with {:ok, _persisted} <- EvaluationRecords.persist_recovery_eval(running_eval, opts) do
      result =
        case EvaluationRecords.fetch_eval_job(running_eval, opts) do
          {:ok, job} ->
            run_recovery_eval(running_eval, job, opts)

          {:error, reason} ->
            Results.failed(
              EvaluationRecords.eval_job(running_eval),
              "could not load recovery eval job: #{inspect(reason)}"
            )
        end

      finalize_recovery_eval(running_eval, result, opts)
      result
    else
      {:error, reason} ->
        Results.failed(
          EvaluationRecords.eval_job(running_eval),
          "could not persist running recovery eval: #{inspect(reason)}"
        )
    end
  end

  defp run_recovery_eval(eval, job, opts) do
    eval_opts =
      opts
      |> Keyword.put(:eval, eval)
      |> Keyword.put(:reason, Map.get(eval, "reason") || Keyword.get(opts, :reason))

    case Map.get(eval, "trigger") do
      "lease_lost" ->
        Recovery.reconcile_orphaned_job(job, eval_opts)

      "restart_exhausted" ->
        Recovery.recover_agents_or_fallback(
          job,
          Map.get(eval, "failed_node"),
          Map.get(eval, "affected_agents", []),
          Map.get(eval, "reason") || "restart policy exhausted",
          eval_opts
        )

      _trigger ->
        Recovery.reconcile_affected_job(job, Map.get(eval, "failed_node"), eval_opts)
    end
  end

  defp finalize_recovery_eval(eval, result, opts) do
    now = Runtime.timestamp()
    {status, wait_until} = eval_status_for_result(eval, result, opts)

    updates =
      %{
        "status" => status,
        "result" => Options.stringify_result(result),
        "block_reason" => if(status == "blocked", do: result.reason, else: nil),
        "wait_until" => wait_until,
        "completed_at" => if(status in ["complete", "failed"], do: now, else: nil),
        "updated_at" => now,
        "history" => EvaluationRecords.append_eval_history(eval, status, result.reason)
      }

    _ = EvaluationRecords.update_recovery_eval(eval["eval_id"], updates, opts)
    :ok
  end

  defp eval_status_for_result(_eval, %{action: :recovered}, _opts), do: {"complete", nil}

  defp eval_status_for_result(_eval, %{action: :paused_for_review}, _opts), do: {"complete", nil}

  defp eval_status_for_result(_eval, %{action: :skipped}, _opts), do: {"complete", nil}

  defp eval_status_for_result(_eval, %{action: :failed}, _opts), do: {"failed", nil}

  defp eval_status_for_result(eval, %{action: :blocked, wait_until: wait_until}, opts),
    do: {"blocked", wait_until || Timing.retry_wait_until(eval, opts)}

  defp eval_status_for_result(eval, %{action: :blocked}, opts),
    do: {"blocked", Timing.retry_wait_until(eval, opts)}

  defp eval_status_for_result(_eval, _result, _opts), do: {"failed", nil}

  def safe_eval_result(eval, opts, fun) do
    fun.()
  rescue
    error ->
      reason = "recovery eval #{Map.get(eval, "eval_id")} exception: #{Exception.message(error)}"
      result = Results.failed(EvaluationRecords.eval_job(eval), reason)
      mark_eval_failed(eval, result, reason, opts)
      result
  catch
    kind, reason ->
      reason = "recovery eval #{Map.get(eval, "eval_id")} #{kind}: #{inspect(reason)}"
      result = Results.failed(EvaluationRecords.eval_job(eval), reason)
      mark_eval_failed(eval, result, reason, opts)
      result
  end

  defp mark_eval_failed(%{"eval_id" => eval_id} = eval, result, reason, opts) do
    now = Runtime.timestamp()

    _ =
      EvaluationRecords.update_recovery_eval(
        eval_id,
        %{
          "status" => "failed",
          "result" => Options.stringify_result(result),
          "block_reason" => nil,
          "wait_until" => nil,
          "completed_at" => now,
          "updated_at" => now,
          "history" => EvaluationRecords.append_eval_history(eval, "failed", reason)
        },
        opts
      )

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp mark_eval_failed(_eval, _result, _reason, _opts), do: :ok
end
