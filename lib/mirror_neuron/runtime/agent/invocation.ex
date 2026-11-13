defmodule MirrorNeuron.Runtime.AgentWorker.Invocation do
  @moduledoc "Admits durable invocations and replays checkpointed actions without repeating effects."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AgentWorker.Actions
  alias MirrorNeuron.Runtime.AgentWorker.Observations
  alias MirrorNeuron.Runtime.AgentWorker.Reports
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.EventBus

  def process_message_result(message, state) do
    case MirrorNeuron.Runtime.InvocationOutbox.admit(message, state) do
      {:ok, admitted} -> process_admitted_message(admitted, state)
      :skip -> {:ok, state}
      {:defer, reason} -> {:defer, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp process_admitted_message(message, state) do
    state = %{state | inflight_message: message}
    Observations.persist_observation(state)

    workflow = Reports.workflow_context(message, state)

    context = %{
      job_id: state.job_id,
      node: state.node,
      coordinator: state.coordinator,
      outbound_edges: state.outbound_edges,
      inbound_edges: state.inbound_edges,
      bundle_root: state.runtime_context[:bundle_root],
      manifest_path: state.runtime_context[:manifest_path],
      payloads_path: state.runtime_context[:payloads_path],
      artifact_refs: state.runtime_context[:artifact_refs] || [],
      template_type: Map.get(state.node, :type, "generic"),
      invocation: state.processed_messages + 1,
      lease_epoch: state.runtime_context[:lease_epoch],
      job_attempt: state.runtime_context[:attempt],
      workflow: workflow,
      coordinator_reporter: fn kind, fields, delivery_key ->
        Reports.enqueue_coordinator_report(state, message, kind, fields, delivery_key)
      end
    }

    with :ok <- command_execution_receipt(message, state),
         :ok <- Reports.maybe_report_workflow_message(state, message, workflow, "received") do
      EventBus.publish(state.job_id, %{
        type: :agent_message_received,
        agent_id: state.node.node_id,
        payload: Message.summary(message),
        attempt: state.runtime_context[:attempt],
        lease_epoch: state.runtime_context[:lease_epoch],
        timestamp: Runtime.timestamp()
      })

      handle_agent_message(message, state, context, workflow)
    else
      {:error, reason} ->
        Observations.persist_observation(state)

        if capacity_wait?(reason),
          do: {:defer, reason, state},
          else: {:error, {:coordinator_report_failed, reason}, state}
    end
  end

  defp command_execution_receipt(message, state) do
    case MirrorNeuron.Runtime.CommandReceipts.executing(message, state) do
      {:error, reason} -> {:error, {:retry_later, reason}}
      _ -> :ok
    end
  end

  defp handle_agent_message(message, state, context, workflow) do
    case MirrorNeuron.Runtime.InvocationOutbox.run(message, state, fn ->
           state.module.handle_message(message, state.local_state, context)
           |> workflow_handler_result(workflow, state.node.node_id)
         end) do
      {:checkpointed, new_local_state, actions, sequence, response} ->
        next_state =
          %{
            state
            | local_state: new_local_state,
              processed_messages: sequence,
              inflight_message: nil
          }

        case Actions.execute_actions(actions, message, next_state) do
          :ok ->
            case Reports.maybe_report_workflow_message(state, message, workflow, "acked") do
              :ok ->
                case MirrorNeuron.Runtime.CommandReceipts.complete(message, next_state, response) do
                  {:error, reason} -> {:defer, {:response_pending, reason}, next_state}
                  _ -> {:ok, next_state}
                end

              {:error, reason} ->
                {:defer, {:coordinator_report_pending, reason},
                 %{next_state | inflight_message: message}}
            end

          {:error, reason} ->
            failed_state = %{next_state | inflight_message: message}
            Observations.persist_observation(failed_state)

            if capacity_wait?(reason),
              do: {:defer, reason, %{next_state | inflight_message: message}},
              else: {:error, {:output_delivery_failed, reason}, failed_state}
        end

      {:defer, reason, new_local_state} ->
        {:defer, reason, %{state | local_state: new_local_state}}

      {:error, reason, new_local_state} ->
        failed_state = %{state | local_state: new_local_state, inflight_message: message}
        Observations.persist_observation(failed_state)
        {:error, reason, failed_state}
    end
  end

  # Once the handler has reported an outcome, the ledger owns its retry.
  # The transport can replay this report without executing the handler again.

  defp workflow_handler_result(
         {:error, reason, local},
         %{"attempt_id" => id} = workflow,
         agent_id
       )
       when is_binary(id) do
    error =
      ErrorEnvelope.normalize(reason,
        component: "workflow_ledger",
        agent_id: agent_id,
        step_id: workflow["step_id"],
        attempt: workflow["attempt"]
      )

    {:ok, local, [{:event, :workflow_step_failed, %{"error" => error}}]}
  end

  defp workflow_handler_result(result, _workflow, _agent_id), do: result

  defp capacity_wait?({:backpressure, _}), do: true

  defp capacity_wait?({:delivery_backpressure, _, _}), do: true

  defp capacity_wait?({:retry_later, _}), do: true

  defp capacity_wait?(_), do: false
end
