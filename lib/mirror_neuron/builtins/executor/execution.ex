defmodule MirrorNeuron.Builtins.Executor.Execution do
  @moduledoc "Executes leased work, emits bounded outcomes and always releases its pool lease."

  alias MirrorNeuron.Builtins.Executor.Actions
  alias MirrorNeuron.Builtins.Executor.Artifacts
  alias MirrorNeuron.Builtins.Executor.Events
  alias MirrorNeuron.Builtins.Executor.Invocation
  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Message
  alias MirrorNeuron.Builtins.Executor.Retry

  def run_under_lease(payload, state, context, normalized_message, lease, lease_manager) do
    Events.report_event(context, :executor_lease_acquired, %{
      "lease_id" => lease["lease_id"],
      "pool" => lease["pool"],
      "slots" => lease["slots"],
      "queue_wait_ms" => lease["queue_wait_ms"]
    })

    case Invocation.run_with_retry(payload, state, context, normalized_message) do
      {:ok, result, attempts} ->
        with {:ok, default_payload} <-
               Artifacts.bounded_default_payload(
                 result,
                 payload,
                 attempts,
                 lease,
                 state.config,
                 context
               ) do
          routed_output_payload =
            Artifacts.routed_output_payload(result, default_payload, payload)

          case Actions.structured_actions(
                 result,
                 state,
                 normalized_message,
                 routed_output_payload,
                 context
               ) do
            {:ok, structured_state, structured_actions} ->
              {structured_output_actions, structured_control_actions} =
                Enum.split_with(structured_actions, &Actions.output_action?/1)

              actions =
                [
                  {:event, :sandbox_job_completed,
                   %{
                     "sandbox_name" => result["sandbox_name"],
                     "exit_code" => result["exit_code"],
                     "attempts" => attempts,
                     "lease_id" => lease["lease_id"],
                     "pool" => lease["pool"]
                   }}
                ] ++
                  structured_control_actions ++
                  Actions.implicit_workflow_step_completion_actions(
                    context,
                    routed_output_payload,
                    structured_actions,
                    state.config
                  ) ++
                  Actions.default_output_actions(state.config, routed_output_payload) ++
                  structured_output_actions

              {:ok,
               %{
                 state
                 | runs: state.runs + 1,
                   agent_state: structured_state,
                   last_output_payload: routed_output_payload,
                   last_result: Map.put(Map.put(result, "attempts", attempts), "lease", lease),
                   last_error: nil
               }, actions}

            {:error, reason} ->
              {:error, reason, %{state | runs: state.runs + 1, last_error: inspect(reason)}}
          end
        else
          {:error, reason} ->
            error = %{"error" => "failed to stage executor result", "reason" => inspect(reason)}
            {:error, error, %{state | runs: state.runs + 1, last_error: inspect(error)}}
        end

      {:error, reason, attempts} ->
        error = Retry.enrich_error(reason, attempts)

        case Map.get(state.config, "failure_message_type") do
          message_type when is_binary(message_type) and message_type != "" ->
            metadata =
              case Map.get(payload, "_mn_step") do
                value when is_map(value) -> value
                _ -> %{}
              end

            diagnostics =
              case Map.get(metadata, "diagnostics") do
                value when is_map(value) -> value
                _ -> %{}
              end

            fallback_metadata =
              Map.put(
                metadata,
                "diagnostics",
                Map.merge(diagnostics, %{
                  "fallback_used" => true,
                  "failed_agent_id" => context.node.node_id
                })
              )

            fallback_payload = %{
              "agent_id" => context.node.node_id,
              "outputs" => %{
                "error" => error,
                "fallback_used" => true,
                "failed_agent_id" => context.node.node_id
              },
              "artifacts" => Message.artifacts(normalized_message),
              "status" => "failed",
              "_mn_step" => fallback_metadata
            }

            {:ok,
             %{
               state
               | runs: state.runs + 1,
                 last_output_payload: fallback_payload,
                 last_error: inspect(error)
             },
             [
               {:event, :executor_fallback_dispatched,
                %{"agent_id" => context.node.node_id, "error" => error}},
               {:emit, message_type, fallback_payload,
                [artifacts: Message.artifacts(normalized_message)]}
             ]}

          _ ->
            {:error, error, %{state | runs: state.runs + 1, last_error: inspect(error)}}
        end
    end
  after
    LeaseManager.release(lease_manager, lease["lease_id"])

    Events.report_event(context, :executor_lease_released, %{
      "lease_id" => lease["lease_id"],
      "pool" => lease["pool"],
      "slots" => lease["slots"]
    })
  end
end
