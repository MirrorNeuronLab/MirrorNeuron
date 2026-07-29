defmodule MirrorNeuron.Operations do
  @moduledoc false

  alias MirrorNeuron.Cluster.{Control, NodeDrainer, Reconciler}
  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Operations.Supervisor
  alias MirrorNeuron.Persistence.OperationStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Scheduler

  @kinds %{
    "cancel_all_jobs" => 8,
    "clear_jobs" => 8,
    "reconcile_node" => 2,
    "drain_node" => 2
  }

  def start(kind, opts \\ [])

  def start(kind, opts) when is_atom(kind), do: start(Atom.to_string(kind), opts)

  def start(kind, opts) when is_binary(kind) and is_list(opts) do
    with {:ok, _limit} <- operation_limit(kind),
         {:ok, targets} <- snapshot_targets(kind, opts),
         {:ok, operation} <- OperationStore.create(kind, targets, operation_attrs(opts)),
         :ok <- Supervisor.start_operation(operation["operation_id"]) do
      {:ok, operation}
    end
  end

  def get(operation_id), do: OperationStore.fetch(operation_id)

  def events(operation_id, after_sequence \\ 0),
    do: OperationStore.read_events(operation_id, after_sequence)

  def max_concurrency(kind), do: Map.get(@kinds, to_string(kind))
  def known_kind?(kind), do: not is_nil(max_concurrency(kind))

  def await(operation_id, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_until(operation_id, deadline)
  end

  def await_settled(operation_id, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_settled_until(operation_id, deadline)
  end

  def legacy_cancel_all_result(operation) do
    results =
      operation
      |> Map.get("items", %{})
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, "started_at", ""))
      |> Enum.map(fn item ->
        item
        |> Map.get("result", %{})
        |> Map.merge(%{
          "job_id" => get_in(item, ["target", "job_id"]) || item["item_id"],
          "status" => item["status"]
        })
        |> maybe_put_error(item["error"])
      end)

    %{
      "operation_id" => operation["operation_id"],
      "cancelled_count" =>
        Enum.count(results, &(&1["status"] in ["cancelled", "cancellation_pending"])),
      "pending_count" => Enum.count(results, &(&1["status"] == "cancellation_pending")),
      "failed_count" => Enum.count(results, &(&1["status"] == "failed")),
      "results" => results
    }
  end

  def legacy_clear_result(operation) do
    items = Map.values(Map.get(operation, "items", %{}))

    %{
      "operation_id" => operation["operation_id"],
      "cleared_count" => Enum.count(items, &(&1["status"] == "cleared")),
      "failed_count" => Enum.count(items, &(&1["status"] == "failed")),
      "results" => Enum.map(items, &Map.take(&1, ["item_id", "status", "result", "error"]))
    }
  end

  def legacy_reconcile_result(operation) do
    jobs =
      operation
      |> Map.get("items", %{})
      |> Map.values()
      |> Enum.map(&Map.get(&1, "result", %{}))

    Enum.reduce(
      jobs,
      %{
        checked: length(jobs),
        recovered: 0,
        paused: 0,
        blocked: 0,
        skipped: 0,
        failed: 0,
        jobs: jobs
      },
      fn job, acc ->
        case Map.get(job, "action") do
          "recovered" -> Map.update!(acc, :recovered, &(&1 + 1))
          "paused_for_review" -> Map.update!(acc, :paused, &(&1 + 1))
          "blocked" -> Map.update!(acc, :blocked, &(&1 + 1))
          "failed" -> Map.update!(acc, :failed, &(&1 + 1))
          _ -> Map.update!(acc, :skipped, &(&1 + 1))
        end
      end
    )
  end

  def legacy_drain_result(operation) do
    actions =
      operation
      |> Map.get("items", %{})
      |> Map.values()
      |> Enum.map(&Map.get(&1, "result", %{}))

    counters = Enum.frequencies_by(actions, &(Map.get(&1, "status") || "unknown"))

    %{
      "node" => operation["node_name"] || operation["node"],
      "status" => legacy_drain_status(operation, counters),
      "actions" => actions,
      "counters" => Map.put(counters, "checked", length(actions)),
      "operation_id" => operation["operation_id"]
    }
  end

  def execute("cancel_all_jobs", %{"job_id" => job_id}, _opts), do: cancel_item(job_id)
  def execute("clear_jobs", %{"job_id" => job_id}, _opts), do: clear_item(job_id)

  def execute("reconcile_node", %{"job_id" => job_id, "node_name" => node_name}, opts) do
    if control_node?() do
      execute_on_runtime("reconcile_node", %{"job_id" => job_id, "node_name" => node_name}, opts)
    else
      case Reconciler.reconcile_job(job_id, node_name, opts) do
        {:ok, result} -> reconcile_result(result)
        {:error, reason} -> {:failed, %{}, inspect(reason)}
      end
    end
  end

  def execute("drain_node", %{"job_id" => job_id, "node_name" => node_name}, opts) do
    if control_node?() do
      execute_on_runtime("drain_node", %{"job_id" => job_id, "node_name" => node_name}, opts)
    else
      case NodeDrainer.drain_job(job_id, node_name, Keyword.put(opts, :continue, true)) do
        {:ok, result} -> drain_result(result)
        {:error, reason} -> {:failed, %{}, inspect(reason)}
      end
    end
  end

  # A drain with no eligible jobs still has an operator-visible effect: it puts
  # the node into draining/maintenance and removes it from new placement.
  def execute("drain_node", %{"node_name" => node_name}, opts) do
    if control_node?() do
      execute_on_runtime("drain_node", %{"node_name" => node_name}, opts)
    else
      case NodeDrainer.drain_node(node_name, Keyword.put(opts, :continue, true)) do
        {:ok, result} -> drain_result(result)
        {:error, reason} -> {:failed, %{}, inspect(reason)}
      end
    end
  end

  def execute(_kind, _target, _opts), do: {:failed, %{}, "unknown operation target"}

  defp await_until(operation_id, deadline) do
    case get(operation_id) do
      {:ok, operation} ->
        if OperationStore.terminal?(operation) or System.monotonic_time(:millisecond) >= deadline do
          {:ok, operation}
        else
          Process.sleep(50)
          await_until(operation_id, deadline)
        end

      error ->
        error
    end
  end

  defp await_settled_until(operation_id, deadline) do
    case get(operation_id) do
      {:ok, operation} ->
        statuses = OperationStore.item_statuses(operation)
        total = Map.get(operation, "target_count", 0)

        if OperationStore.terminal?(operation) or
             (length(statuses) >= total and Enum.all?(statuses, &(&1 != "running"))) or
             System.monotonic_time(:millisecond) >= deadline do
          {:ok, operation}
        else
          Process.sleep(50)
          await_settled_until(operation_id, deadline)
        end

      error ->
        error
    end
  end

  defp operation_limit(kind) do
    if known_kind?(kind),
      do: {:ok, max_concurrency(kind)},
      else: {:error, "unsupported operation kind #{inspect(kind)}"}
  end

  defp snapshot_targets("cancel_all_jobs", _opts) do
    with {:ok, jobs} <-
           Monitor.list_jobs(limit: 2_147_483_647, include_terminal: false, summary: :basic) do
      targets =
        jobs
        |> Enum.filter(
          &(Map.get(&1, "status") in [
              "pending",
              "validated",
              "scheduled",
              "running",
              "paused",
              "cancelling"
            ])
        )
        |> Enum.map(&%{"id" => &1["job_id"], "job_id" => &1["job_id"]})

      {:ok, targets}
    end
  end

  defp snapshot_targets("clear_jobs", _opts) do
    with {:ok, jobs} <-
           Monitor.list_jobs(limit: 2_147_483_647, include_terminal: true, summary: :basic) do
      {:ok,
       jobs
       |> Enum.filter(
         &(Map.get(&1, "status") in ["completed", "failed", "cancelled", "cancelling"])
       )
       |> Enum.map(&%{"id" => &1["job_id"], "job_id" => &1["job_id"]})}
    end
  end

  defp snapshot_targets(kind, opts) when kind in ["reconcile_node", "drain_node"] do
    node_name = Keyword.get(opts, :node_name) || Keyword.get(opts, :node)

    if is_binary(node_name) and String.trim(node_name) != "" do
      with {:ok, jobs} <- MirrorNeuron.Persistence.RedisStore.list_job_summaries() do
        targets =
          jobs
          |> Enum.filter(&(Map.get(&1, "status") in ["pending", "running", "paused"]))
          |> Enum.filter(&job_on_node?(&1, node_name))
          |> Enum.map(
            &%{"id" => &1["job_id"], "job_id" => &1["job_id"], "node_name" => node_name}
          )

        targets =
          if kind == "drain_node" and targets == [] do
            [%{"id" => "node:" <> node_name, "node_name" => node_name}]
          else
            targets
          end

        {:ok, targets}
      end
    else
      {:error, "node_name is required"}
    end
  end

  defp operation_attrs(opts) do
    opts
    |> Keyword.take([:node_name, :node, :reason, :dry_run, :deadline_ms, :ignore_system_jobs])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp job_on_node?(job, node_name) do
    Scheduler.affected_agent_ids(Map.get(job, "scheduler", %{}), node_name) != [] or
      Map.get(job, "lease_owner") == node_name or
      get_in(job, ["lease", "owner_id"]) == node_name
  end

  defp cancel_item(job_id) do
    case MirrorNeuron.cancel(job_id) do
      {:ok, "cancellation_pending"} ->
        {:cancellation_pending, %{"message" => "cleanup queued on owner node"}, nil}

      {:ok, status} ->
        {to_string(status), %{}, nil}

      {:error, reason} ->
        {:failed, %{}, Runtime.error_message(reason)}
    end
  end

  defp clear_item(job_id) do
    case Runtime.clear_job_with_result(job_id) do
      {:ok, result} -> {:cleared, result, nil}
      {:error, reason} -> {:failed, %{}, Runtime.error_message(reason)}
    end
  end

  defp reconcile_result(result) do
    status = result |> Map.get(:action, Map.get(result, "action", :skipped)) |> to_string()

    case status do
      "failed" ->
        {:failed, stringify(result), Map.get(result, :reason) || Map.get(result, "reason")}

      "blocked" ->
        {:deferred, stringify(result), nil}

      _ ->
        {status, stringify(result), nil}
    end
  end

  defp drain_result(result) do
    status = Map.get(result, "status", "skipped")

    case status do
      "failed" ->
        {:failed, result, Map.get(result, "reason")}

      status when status in ["waiting", "blocked", "blocked_no_placement"] ->
        {:deferred, result, nil}

      _ ->
        {status, result, nil}
    end
  end

  defp maybe_put_error(result, nil), do: result
  defp maybe_put_error(result, error), do: Map.put(result, "error", error)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {if(is_atom(key), do: Atom.to_string(key), else: key), stringify(value)}
    end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp legacy_drain_status(operation, counters) do
    cond do
      Map.get(operation, "status") == "waiting" -> "draining"
      Map.get(counters, "failed", 0) > 0 -> "blocked_no_placement"
      Map.get(counters, "blocked", 0) > 0 -> "blocked_no_placement"
      Map.get(counters, "paused_for_review", 0) > 0 -> "paused_for_review"
      true -> "complete"
    end
  end

  defp execute_on_runtime(kind, target, opts) do
    case Control.call(__MODULE__, :execute, [kind, target, opts]) do
      {:badrpc, reason} -> {:failed, %{}, "runtime operation routing failed: #{inspect(reason)}"}
      {:error, reason} -> {:failed, %{}, "runtime operation routing failed: #{inspect(reason)}"}
      result -> result
    end
  end

  defp control_node?, do: MirrorNeuron.Application.node_role() == "control"
end
