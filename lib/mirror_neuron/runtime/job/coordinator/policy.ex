defmodule MirrorNeuron.Runtime.JobCoordinator.Policy do
  @moduledoc "Restart and reschedule policy state, history and token-fenced timers."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.LifecyclePolicy

  def restart_policy(state, agent_id) do
    LifecyclePolicy.restart_policy(
      state.manifest,
      Topology.job_type(state),
      effective_recovery_policy(state),
      Map.get(state.source_agent_ids, agent_id, agent_id)
    )
  end

  def reschedule_policy(state, agent_id) do
    LifecyclePolicy.reschedule_policy(
      state.manifest,
      Topology.job_type(state),
      effective_recovery_policy(state),
      Map.get(state.source_agent_ids, agent_id, agent_id)
    )
  end

  def job_restart_policy(state) do
    LifecyclePolicy.restart_policy(
      state.manifest,
      Topology.job_type(state),
      effective_recovery_policy(state)
    )
  end

  def job_reschedule_policy(state) do
    LifecyclePolicy.reschedule_policy(
      state.manifest,
      Topology.job_type(state),
      effective_recovery_policy(state)
    )
  end

  def policy_history(state, agent_id, kind) do
    get_in(state.policy_state, ["agents", agent_id, "#{kind}_history"]) || []
  end

  def put_policy_history(state, agent_id, kind, history) do
    put_policy_agent_fields(state, agent_id, %{"#{kind}_history" => history})
  end

  def put_policy_agent_fields(state, agent_id, fields) do
    agents = Map.get(state.policy_state, "agents", %{})
    existing = Map.get(agents, agent_id, %{})

    policy_state =
      state.policy_state
      |> Map.put("agents", Map.put(agents, agent_id, Map.merge(existing, fields)))
      |> Map.put("updated_at", Runtime.timestamp())

    %{state | policy_state: policy_state}
  end

  def mark_policy_idle(state, agent_id) do
    state
    |> clear_policy_timer({:restart, agent_id})
    |> clear_policy_timer({:reschedule, agent_id})
    |> put_policy_agent_fields(agent_id, %{
      "next_action" => nil,
      "next_eligible_at" => nil,
      "exhausted_reason" => nil,
      "last_success_at" => Runtime.timestamp()
    })
  end

  def pending_policy_action?(state, agent_id) do
    agent_state = get_in(state.policy_state, ["agents", agent_id]) || %{}
    not is_nil(Map.get(agent_state, "next_action"))
  end

  def schedule_policy_timer(state, key, message, delay_ms) do
    state = clear_policy_timer(state, key)
    token = make_ref()
    timer_message = {:policy_timer, key, token, message}
    ref = Process.send_after(self(), timer_message, max(delay_ms, 0))

    timer = %{ref: ref, token: token, message: timer_message}
    %{state | pending_policy_timers: Map.put(state.pending_policy_timers, key, timer)}
  end

  def clear_policy_timer(state, key) do
    case Map.pop(state.pending_policy_timers, key) do
      {nil, _timers} ->
        state

      {%{ref: ref, message: message}, timers} ->
        Process.cancel_timer(ref)

        receive do
          ^message -> :ok
        after
          0 -> :ok
        end

        %{state | pending_policy_timers: timers}
    end
  end

  def drop_policy_timer(state, key) do
    %{state | pending_policy_timers: Map.delete(state.pending_policy_timers, key)}
  end

  def cancel_policy_timers(state) do
    Enum.reduce(Map.keys(state.pending_policy_timers), state, &clear_policy_timer(&2, &1))
  end

  def cancel_policy_timers_for(state, agent_ids) do
    Enum.reduce(agent_ids, state, fn agent_id, acc ->
      acc
      |> clear_policy_timer({:restart, agent_id})
      |> clear_policy_timer({:reschedule, agent_id})
    end)
  end

  def reliability_from(opts, existing_job) do
    requested =
      Keyword.get(opts, :requested_recovery_policy) ||
        (is_map(existing_job) && existing_job["requested_recovery_policy"]) ||
        "auto"

    effective =
      Keyword.get(opts, :recovery_policy) ||
        (is_map(existing_job) && existing_job["recovery_policy"]) ||
        if(requested == "auto", do: "local_restart", else: requested)

    defaults = %{
      "mode" => "single_node",
      "requested_recovery_policy" => requested,
      "effective_recovery_policy" => effective,
      "degraded" => false,
      "reason" => "single-node runtime policy",
      "observed_nodes" => [to_string(Node.self())],
      "observed_at" => Runtime.timestamp()
    }

    opts
    |> Keyword.get(
      :reliability,
      if(is_map(existing_job), do: existing_job["reliability"], else: %{})
    )
    |> normalize_reliability()
    |> then(&Map.merge(defaults, &1))
  end

  def effective_recovery_policy(state) do
    get_in(state.reliability, ["effective_recovery_policy"]) ||
      Keyword.get(state.opts, :recovery_policy) ||
      Map.get(state.manifest.policies, "recovery_mode", "local_restart")
  end

  def requested_recovery_policy(state) do
    get_in(state.reliability, ["requested_recovery_policy"]) ||
      Keyword.get(state.opts, :requested_recovery_policy) ||
      Map.get(state.manifest.policies, "recovery_mode", "auto")
  end

  def reliability_degraded?(state), do: get_in(state.reliability, ["degraded"]) == true

  def reliability_map(state) do
    state.reliability
    |> Map.take([
      "mode",
      "effective_recovery_policy",
      "degraded",
      "reason",
      "observed_nodes",
      "observed_at"
    ])
    |> Map.put("restart_policy", job_restart_policy(state))
    |> Map.put("reschedule_policy", job_reschedule_policy(state))
    |> Map.put("policy_state", state.policy_state)
  end

  defp normalize_reliability(reliability) when is_map(reliability), do: reliability

  defp normalize_reliability(_reliability), do: %{}
end
