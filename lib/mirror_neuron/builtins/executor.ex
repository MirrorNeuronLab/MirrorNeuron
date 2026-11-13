defmodule MirrorNeuron.Builtins.Executor do
  use MirrorNeuron.AgentTemplate
  @moduledoc "Generic executor agent and resource-lease admission boundary."

  alias MirrorNeuron.Builtins.Executor.Events
  alias MirrorNeuron.Builtins.Executor.Execution
  alias MirrorNeuron.Builtins.Executor.Invocation
  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Builtins.Executor.Leases
  alias MirrorNeuron.Message
  alias MirrorNeuron.Execution.Profile

  @impl true
  def init(node) do
    with :ok <- MirrorNeuron.Builtins.BlockEventResult.validate_config(node.config["block_event"]) do
      {:ok,
       %{
         config: Profile.apply_to_config(node.config),
         runs: 0,
         agent_state: %{},
         last_output_payload: nil,
         last_result: nil,
         last_error: nil
       }}
    end
  end

  @impl true
  def handle_message(message, state, context) do
    normalized_message =
      Message.normalize!(message, job_id: context.job_id, to: context.node.node_id)

    payload = Message.body(normalized_message) || %{}
    pool = Leases.configured_pool(state.config)
    pool_slots = Leases.configured_pool_slots(state.config)
    lease_manager = Leases.configured_lease_manager(state.config)
    lease_opts = Leases.configured_lease_opts(state.config)

    Invocation.maybe_sleep_startup_delay(state)

    Events.report_event(context, :executor_lease_requested, %{
      "pool" => pool,
      "slots" => pool_slots
    })

    with {:ok, lease} <-
           LeaseManager.acquire(
             lease_manager,
             pool,
             pool_slots,
             Leases.lease_metadata(context),
             lease_opts
           ) do
      Execution.run_under_lease(payload, state, context, normalized_message, lease, lease_manager)
    else
      {:error, {:retry_later, details}} ->
        Events.report_event(context, :executor_lease_rejected, details)

        {:defer, details, state}

      {:error, reason} ->
        {:error, %{"error" => reason},
         %{state | runs: state.runs + 1, last_error: inspect(reason)}}
    end
  end
end
