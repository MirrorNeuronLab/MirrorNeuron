defmodule MirrorNeuron.Runtime.Signals do
  @moduledoc "Immediate failure/response observation, independent of worker/coordinator queues."
  alias MirrorNeuron.Runtime.{ErrorEnvelope, EventEnvelope}
  alias MirrorNeuron.Persistence.SignalStore
  @registry MirrorNeuron.Runtime.SignalRegistry

  def subscribe(run_id, channel) do
    flag = :atomics.new(1, [])
    with {:ok, _} <- Registry.register(@registry, {run_id, channel}, flag), do: {:ok, flag}
  end

  def rearm(flag), do: :atomics.put(flag, 1, 0)
  def delivery_unavailable(run_id, channel), do: unavailable(run_id, channel)

  def publish(run_id, channel, event, incident_id \\ "") do
    event = EventEnvelope.normalize(event, run_id)

    case SignalStore.append(run_id, channel, event, incident_id) do
      {:ok, saved, true} ->
        notify(run_id, channel)
        {:ok, saved}

      {:ok, saved, false} ->
        {:ok, saved}

      {:error, reason} ->
        unavailable(run_id, channel)
        {:error, reason}
    end
  end

  def error(run_id, agent_id, correlation_id, reason, state \\ :observed, opts \\ []) do
    error = ErrorEnvelope.normalize(reason, Keyword.put(opts, :agent_id, agent_id))

    id =
      :crypto.hash(
        :sha256,
        Enum.join([run_id, agent_id, to_string(correlation_id), error["code"]], ":")
      )
      |> Base.encode16(case: :lower)

    now = MirrorNeuron.Runtime.timestamp()

    publish(
      run_id,
      "errors",
      %{
        "type" => "runtime.error_#{state}",
        "level" => if(state == :recovered, do: "info", else: "error"),
        "run_id" => run_id,
        "agent_id" => agent_id,
        "payload" => %{
          "incident_id" => id,
          "correlation_id" => correlation_id,
          "step_id" => get_in(error, ["details", "step_id"]),
          "state" => to_string(state),
          "error" => error,
          "count" => 1,
          "first_occurred_at" => now,
          "last_occurred_at" => now
        }
      },
      id
    )
  end

  def resolve(run_id, agent_id, correlation_id, state \\ :recovered) do
    with {:ok, incidents} <- SignalStore.read(run_id, "errors", 0) do
      incidents
      |> Enum.filter(fn event ->
        event["agent_id"] == agent_id and event["payload"]["correlation_id"] == correlation_id and
          event["payload"]["state"] in ["observed", "retrying"]
      end)
      |> Enum.each(fn event ->
        error(run_id, agent_id, correlation_id, event["payload"]["error"], state)
      end)

      :ok
    end
  end

  def workflow(run_id, event) do
    type = to_string(event[:type] || event["type"])
    payload = event[:payload] || event["payload"] || event

    agent =
      to_string(
        event[:agent_id] || event["agent_id"] || payload[:agent_id] || payload["agent_id"] ||
          "workflow"
      )

    step =
      payload[:step_id] || payload["step_id"] || payload[:step] || payload["step"] || "workflow"

    cond do
      type in ["workflow_step_failed", "workflow_step_timed_out", "workflow_step_attempt_failed"] ->
        error(
          run_id,
          agent,
          step,
          payload[:error] || payload["error"] || payload[:reason] || payload["reason"] || type
        )

      type in ["workflow_step_completed", "workflow_step_partial"] ->
        resolve(run_id, agent, step)

        with {:ok, incidents} <- SignalStore.read(run_id, "errors", 0) do
          Enum.each(incidents, fn event ->
            if event["payload"]["step_id"] == step and
                 event["payload"]["state"] in ["observed", "retrying"],
               do:
                 error(
                   run_id,
                   event["agent_id"],
                   event["payload"]["correlation_id"],
                   event["payload"]["error"],
                   :recovered
                 )
          end)
        end

      true ->
        :ok
    end
  end

  def finish_run_async(run_id, status) when status in ["completed", "failed", "cancelled"] do
    result =
      Task.Supervisor.start_child(MirrorNeuron.Runtime.SignalTaskSupervisor, fn ->
        with {:ok, incidents} <- SignalStore.read(run_id, "errors", 0) do
          for event <- incidents, event["payload"]["state"] in ["observed", "retrying"] do
            error(
              run_id,
              event["agent_id"],
              event["payload"]["correlation_id"],
              event["payload"]["error"],
              if(status == "completed", do: :recovered, else: :terminal)
            )
          end
        else
          _ -> unavailable(run_id, "errors")
        end
      end)

    if match?({:error, _}, result), do: unavailable(run_id, "errors")
    result
  catch
    :exit, _ -> unavailable(run_id, "errors")
  end

  def notify(run_id, channel) do
    notify_local(run_id, channel)
    for peer <- Node.list(), do: :rpc.cast(peer, __MODULE__, :notify_local, [run_id, channel])
    :ok
  end

  @doc false
  def notify_local(run_id, channel) do
    if Process.whereis(@registry) do
      Registry.dispatch(@registry, {run_id, channel}, fn subscribers ->
        Enum.each(subscribers, fn {pid, flag} ->
          if :atomics.compare_exchange(flag, 1, 0, 1) == :ok,
            do: send(pid, {:runtime_signal_available, channel})
        end)
      end)
    end

    :ok
  end

  defp unavailable(run_id, channel) do
    unavailable_local(run_id, channel)

    for peer <- Node.list(),
        do: :rpc.cast(peer, __MODULE__, :unavailable_local, [run_id, channel])

    :ok
  end

  @doc false
  def unavailable_local(run_id, channel) do
    if Process.whereis(@registry) do
      Registry.dispatch(@registry, {run_id, channel}, fn subscribers ->
        Enum.each(subscribers, fn {pid, flag} ->
          if :atomics.exchange(flag, 1, 2) != 2,
            do: send(pid, {:runtime_signal_unavailable, channel})
        end)
      end)
    end
  end
end
