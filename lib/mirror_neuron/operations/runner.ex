defmodule MirrorNeuron.Operations.Runner do
  @moduledoc false

  use GenServer

  alias MirrorNeuron.Operations
  alias MirrorNeuron.Persistence.OperationStore

  @runner_ttl_ms 30_000
  @renew_interval_ms 10_000

  def start_link(operation_id) do
    GenServer.start_link(__MODULE__, operation_id)
  end

  @impl true
  def init(operation_id) do
    owner = "#{Node.self()}:#{System.unique_integer([:positive])}"

    case OperationStore.claim_runner(operation_id, owner, @runner_ttl_ms) do
      :ok ->
        send(self(), :run)
        {:ok, %{operation_id: operation_id, owner: owner, task_ref: nil}}

      {:error, :claimed} ->
        {:stop, :normal}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:run, state) do
    task =
      Task.Supervisor.async_nolink(MirrorNeuron.Runtime.RecoveryTaskSupervisor, fn ->
        run(state.operation_id)
      end)

    Process.send_after(self(), :renew, @renew_interval_ms)
    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_info(:renew, state) do
    case OperationStore.renew_runner(state.operation_id, state.owner, @runner_ttl_ms) do
      :ok ->
        Process.send_after(self(), :renew, @renew_interval_ms)
        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info({ref, _result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    OperationStore.release_runner(state.operation_id, state.owner)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    OperationStore.release_runner(state.operation_id, state.owner)
    {:stop, :normal, state}
  end

  defp run(operation_id) do
    with {:ok, operation} <- OperationStore.fetch(operation_id),
         false <- OperationStore.terminal?(operation) do
      operation = mark_running(operation)
      opts = operation_opts(operation)
      limit = Operations.max_concurrency(operation["kind"])

      Task.Supervisor.async_stream_nolink(
        MirrorNeuron.Runtime.RecoveryTaskSupervisor,
        pending_targets(operation),
        fn target -> run_item(operation_id, operation["kind"], target, opts) end,
        max_concurrency: limit,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      finalize(operation_id)
    else
      true -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp mark_running(%{"status" => "pending"} = operation) do
    {:ok, next} =
      OperationStore.update(operation["operation_id"], fn current ->
        current
        |> Map.put("status", "running")
        |> Map.put("started_at", current["started_at"] || timestamp())
      end)

    _ = OperationStore.append_event(next["operation_id"], %{"type" => "operation_started"})
    next
  end

  defp mark_running(operation), do: operation

  defp pending_targets(operation) do
    items = Map.get(operation, "items", %{})

    Enum.filter(operation["targets"], fn target ->
      case Map.get(items, target["id"]) do
        nil -> true
        %{"status" => status} -> status in ["running", "deferred"]
      end
    end)
  end

  defp run_item(operation_id, kind, target, opts) do
    _ = OperationStore.start_item(operation_id, target)

    case Operations.execute(kind, target, opts) do
      {status, result, error} ->
        _ = OperationStore.finish_item(operation_id, target, to_string(status), result, error)

      other ->
        _ = OperationStore.finish_item(operation_id, target, "failed", %{}, inspect(other))
    end
  rescue
    error ->
      _ =
        OperationStore.finish_item(operation_id, target, "failed", %{}, Exception.message(error))
  catch
    kind, reason ->
      _ =
        OperationStore.finish_item(
          operation_id,
          target,
          "failed",
          %{},
          "#{kind}: #{inspect(reason)}"
        )
  end

  defp finalize(operation_id) do
    with {:ok, operation} <- OperationStore.fetch(operation_id) do
      counters = OperationStore.counters(operation)
      statuses = OperationStore.item_statuses(operation)

      status =
        cond do
          Enum.any?(statuses, &(&1 == "deferred")) -> "waiting"
          counters["failed"] > 0 -> "completed_with_failures"
          true -> "completed"
        end

      {:ok, next} =
        OperationStore.update(operation_id, fn current ->
          current
          |> Map.put("status", status)
          |> Map.put("counters", counters)
          |> maybe_completed_at(status)
        end)

      event_type = if status == "waiting", do: "operation_deferred", else: "operation_completed"

      _ =
        OperationStore.append_event(operation_id, %{
          "type" => event_type,
          "status" => status,
          "counters" => next["counters"]
        })
    end
  end

  defp maybe_completed_at(operation, "waiting"), do: operation
  defp maybe_completed_at(operation, _status), do: Map.put(operation, "completed_at", timestamp())

  defp operation_opts(operation) do
    operation
    |> Map.take(["node_name", "node", "reason", "dry_run", "deadline_ms", "ignore_system_jobs"])
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
  rescue
    ArgumentError -> []
  end

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
