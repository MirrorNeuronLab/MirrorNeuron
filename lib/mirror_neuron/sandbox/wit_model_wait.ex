defmodule MirrorNeuron.Sandbox.WitModelWait do
  @moduledoc "Observe an admitted model-backed WIT call while its guest is blocked in the import."
  alias MirrorNeuron.ModelServices.Commands
  alias MirrorNeuron.Runner.CommandBudget
  alias MirrorNeuron.Runner.HostLocal.Beacons

  @poll_ms 2_000

  def bind(command, nil), do: command
  def bind(command, id), do: Map.put(command, "observation_id", id)

  def run(runner, ref, sdk_node, beacon_timeout, invoke) do
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    status = %{"kind" => "wit_model_status", "observation_id" => id}
    task = Task.async(fn -> invoke_model(invoke, id) end)

    try do
      result =
        await(task, sdk_node, status, runner, ref, max(1, min(@poll_ms, div(beacon_timeout, 3))))

      outcome = if match?({:ok, _}, result), do: "completed", else: "failed"
      send(runner, {:wit_model_status, ref, {:finished, outcome}})
      result
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp invoke_model(invoke, id) do
    invoke.(id)
  rescue
    _ -> {:error, :model_request_failed}
  catch
    :exit, _ -> {:error, :model_request_failed}
  end

  defp await(task, sdk_node, status, runner, ref, interval) do
    case Task.yield(task, interval) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, :model_request_failed}

      nil ->
        result =
          if sdk_node == node(),
            do: Commands.job_response_command(status, {:at_most, interval}),
            else:
              :rpc.call(
                sdk_node,
                Commands,
                :job_response_command,
                [status, {:at_most, interval}],
                interval + 1_000
              )

        case result do
          {:ok, %{"pending" => true} = snapshot} ->
            send(runner, {:wit_model_status, ref, snapshot})

          _ ->
            :ok
        end

        await(task, sdk_node, status, runner, ref, interval)
    end
  end

  def observe(state, %{"pending" => true} = status, now) do
    state
    |> Map.put(:last_wit_check_at, now)
    |> Map.put(:wit_pending, true)
    |> preparation(status["preparation"], now)
  end

  def observe(%{wit_pending: true} = state, {:finished, outcome}, now) do
    state
    |> Map.put(:last_wit_check_at, now)
    |> Map.delete(:wit_pending)
    |> finish(outcome, now)
  end

  def observe(state, _, _), do: state

  defp preparation(state, snapshot, now) do
    previous = state[:wit_preparation]
    current = receipt(snapshot)

    cond do
      previous == current ->
        state

      previous && (is_nil(current) or previous["preparation_id"] != current["preparation_id"]) ->
        state
        |> finish("completed", now)
        |> preparation(current, now)

      current ->
        type =
          if previous, do: "runtime_preparation_progress", else: "runtime_preparation_started"

        state |> event(type, current, now) |> Map.put(:wit_preparation, current)
    end
  end

  defp finish(%{wit_preparation: receipt} = state, outcome, now) do
    phase = if outcome == "completed", do: "ready", else: "failed"

    state
    |> event(
      "runtime_preparation_finished",
      Map.merge(receipt, %{"status" => outcome, "phase" => phase, "percent" => nil}),
      now
    )
    |> Map.delete(:wit_preparation)
  end

  defp finish(state, _, _), do: state

  defp receipt(
         %{"preparation_id" => id, "timeout_ms" => ms, "purpose" => purpose, "phase" => phase} =
           value
       )
       when is_binary(id) and byte_size(id) in 1..128 and is_integer(ms) and ms in 1..86_400_000 and
              purpose in ["llm", "embedding"] and
              phase in ["preparing", "downloading", "loading", "waiting"] do
    percent = value["percent"]

    receipt = %{
      "preparation_id" => id,
      "timeout_ms" => ms,
      "kind" => "model",
      "purpose" => purpose,
      "phase" => phase,
      "percent" => if(is_number(percent) and percent >= 0 and percent <= 100, do: percent)
    }

    if value["timeout_policy"] == "download_inactivity" do
      bytes = value["current_bytes"]

      Map.merge(receipt, %{
        "timeout_policy" => "download_inactivity",
        "current_bytes" => if(is_integer(bytes) and bytes >= 0, do: bytes)
      })
    else
      receipt
    end
  end

  defp receipt(_), do: nil

  defp event(state, type, receipt, now) do
    attempt = state.budget.step["current_attempt"]["attempt_id"]

    payload =
      Beacons.agent_event_payload(state, Map.put(receipt, "attempt_id", attempt))
      |> Map.put("source", "runtime")

    Beacons.emit_beacon_event(state, type, payload)
    %{state | budget: CommandBudget.observe(state.budget, type, payload, now)}
  end
end
