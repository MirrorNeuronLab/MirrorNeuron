defmodule MirrorNeuron.Builtins.Executor.Invocation do
  @moduledoc "Dispatches runner attempts under current retry configuration and durable error reporting."

  alias MirrorNeuron.Builtins.Executor.Artifacts
  alias MirrorNeuron.Builtins.Executor.Events
  alias MirrorNeuron.Message
  alias MirrorNeuron.Builtins.Executor.Retry
  alias MirrorNeuron.Runner

  def maybe_sleep_startup_delay(%{runs: 0, config: config}) do
    case Map.get(config, "startup_delay_ms", 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  def maybe_sleep_startup_delay(_state), do: :ok

  def run_with_retry(payload, state, context, message),
    do: run_with_retry(payload, state, context, message, 1)

  def run_with_retry(payload, state, context, message, attempt) do
    case MirrorNeuron.Runtime.RunRetry.invocation_config(state.config, context) do
      {:ok, config} ->
        run_configured_invocation(payload, %{state | config: config}, context, message, attempt)

      {:error, reason} ->
        {:error, reason, attempt}
    end
  end

  defp run_configured_invocation(payload, state, context, message, attempt) do
    config = state.config
    runner_config = Artifacts.with_step_result_pointer(config, context, attempt)

    # We pass the overall invocation counter (to salt sandbox directories securely between distinct payloads or retries)
    invocation = Map.get(context, :invocation, 1)

    case Runner.run(
           payload,
           runner_config,
           message: message,
           attempt: attempt,
           run_id: get_in(context, [:workflow, "run_id"]),
           step_instance: step_instance(context, runner_config, message),
           runtime_attempt:
             get_in(context, [:workflow, "attempt"]) || Map.get(context, :job_attempt) ||
               attempt,
           lease_epoch: Map.get(context, :lease_epoch),
           invocation: invocation,
           coordinator_node: node(context.coordinator),
           job_id: context.job_id,
           agent_id: context.node.node_id,
           agent_type: Map.get(context.node, :agent_type),
           template_type: Map.get(context.node, :type, "generic"),
           agent_state: state.agent_state,
           bundle_root: context.bundle_root,
           manifest_path: context.manifest_path,
           payloads_path: context.payloads_path,
           event_callback: fn event_type, event_payload ->
             Events.report_event(context, event_type, event_payload)
           end
         ) do
      {:ok, result} ->
        case Artifacts.await_structured_result(result, runner_config, context) do
          {:ok, result} ->
            if attempt > 1,
              do:
                MirrorNeuron.Runtime.Signals.resolve(
                  context.job_id,
                  context.node.node_id,
                  Message.id(message)
                )

            {:ok, result, attempt}

          {:error, reason} ->
            report_invocation_error(context, message, reason, :observed)

            if Retry.retryable?(reason) and attempt < Retry.max_attempts(config) do
              report_invocation_error(context, message, reason, :retrying)
              Process.sleep(Retry.backoff_ms(config, attempt))

              run_with_retry(
                payload,
                %{state | last_error: reason},
                context,
                message,
                attempt + 1
              )
            else
              {:error, reason, attempt}
            end
        end

      {:error, reason} ->
        report_invocation_error(context, message, reason, :observed)

        if Retry.retryable?(reason) and attempt < Retry.max_attempts(config) do
          report_invocation_error(context, message, reason, :retrying)
          Process.sleep(Retry.backoff_ms(config, attempt))
          run_with_retry(payload, %{state | last_error: reason}, context, message, attempt + 1)
        else
          {:error, reason, attempt}
        end
    end
  end

  defp report_invocation_error(context, message, reason, status) do
    MirrorNeuron.Runtime.Signals.error(
      context.job_id,
      context.node.node_id,
      Message.id(message),
      reason,
      status,
      step_id: get_in(context, [:workflow, "step_id"])
    )
  end

  defp step_instance(context, %{"block_event" => _}, message),
    do: "event:" <> context.node.node_id <> ":" <> Message.id(message)

  defp step_instance(context, _config, _message),
    do: (get_in(context, [:workflow, "step_id"]) || "step") <> ":" <> context.node.node_id
end
