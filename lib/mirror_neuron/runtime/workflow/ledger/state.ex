defmodule MirrorNeuron.Runtime.WorkflowLedger.State do
  @moduledoc "Workflow state access, lifecycle fields and recovery of persisted steps."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.WorkflowLedger.Values

  @schema_version 3
  @successful_step_statuses ["completed", "partial", "skipped"]
  @terminal_step_statuses @successful_step_statuses ++ ["failed"]

  def disabled_state do
    %{"schema_version" => @schema_version, "enabled" => false}
  end

  def enabled?(%{"enabled" => true}), do: true

  def enabled?(_state), do: false

  def run_id(%{"run_id" => run_id}) when is_binary(run_id), do: run_id

  def run_id(_state), do: nil

  def agent_to_step(%{"agent_to_step" => mapping}) when is_map(mapping), do: mapping

  def agent_to_step(_state), do: %{}

  def step_for_agent(state, agent_id) when is_binary(agent_id) do
    state
    |> agent_to_step()
    |> Map.get(agent_id)
  end

  def step_for_agent(_state, _agent_id), do: nil

  def active_step_for_agent(%{"steps" => steps, "step_order" => step_order}, agent_id)
      when is_map(steps) and is_binary(agent_id) do
    step_order
    |> Enum.find_value(fn step_id ->
      case Map.get(steps, step_id) do
        %{"agent_ids" => agent_ids, "status" => status}
        when is_list(agent_ids) and status in ["queued", "running", "retry_wait"] ->
          if agent_id in agent_ids, do: step_id

        _ ->
          nil
      end
    end)
  end

  def active_step_for_agent(_state, _agent_id), do: nil

  def completed?(%{"enabled" => true, "steps" => steps}) when is_map(steps) do
    map_size(steps) > 0 and
      Enum.all?(Map.values(steps), &(Map.get(&1, "status") in @successful_step_statuses))
  end

  def completed?(_state), do: false

  def active_agent_ids(%{"steps" => steps}) when is_map(steps) do
    steps
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, "status") in ["queued", "running", "retry_wait"]))
    |> Enum.flat_map(&Map.get(&1, "agent_ids", []))
    |> Enum.uniq()
  end

  def active_agent_ids(_state), do: []

  def merge_existing(base, existing_job) when is_map(existing_job) do
    case Map.get(existing_job, "workflow_state") do
      %{"enabled" => true} = existing ->
        existing_steps = Map.get(existing, "steps", %{})

        merged_base_steps =
          base["steps"]
          |> Enum.into(%{}, fn {step_id, step} ->
            existing_step = Map.get(existing_steps, step_id, %{})
            {step_id, Map.merge(step, existing_step)}
          end)

        persisted_mapped_steps =
          existing_steps
          |> Enum.filter(fn {step_id, step} ->
            not Map.has_key?(base["steps"], step_id) and is_map(step) and
              (is_integer(Map.get(step, "map_index")) or
                 Map.get(step, "dynamic_instance") == true)
          end)
          |> Map.new()

        steps =
          Map.merge(merged_base_steps, persisted_mapped_steps)
          |> Map.new(fn {id, step} -> {id, Map.delete(step, "inspection")} end)

        persisted_order =
          existing
          |> Map.get("step_order", [])
          |> List.wrap()
          |> Enum.filter(&Map.has_key?(steps, &1))

        step_order =
          (persisted_order ++
             Enum.reject(Map.keys(steps), &(&1 in persisted_order)))
          |> Enum.uniq()

        edges =
          case Map.get(existing, "edges") do
            edges when is_list(edges) -> edges
            _ -> base["edges"]
          end

        base
        |> Map.merge(
          Map.take(existing, [
            "created_at",
            "job_id",
            "run_id",
            "status",
            "paused_at",
            "messages",
            "mode",
            "dynamic_enabled",
            "graph_revision",
            "dynamic_limits",
            "dynamic_templates",
            "dynamic_regions",
            "applied_patches",
            "patch_order",
            "dynamic_patch_instances",
            "dynamic_history",
            "child_workflows"
          ])
        )
        |> Map.put("steps", steps)
        |> Map.put("step_order", step_order)
        |> Map.put("edges", edges)
        |> Map.put("updated_at", Runtime.timestamp())

      _ ->
        base
    end
  end

  def merge_existing(base, _existing_job), do: base

  def existing_run_id(%{"workflow_state" => %{"run_id" => run_id}}) when is_binary(run_id),
    do: run_id

  def existing_run_id(_existing_job), do: Values.unique_id()

  def existing_job_id(%{"job_id" => job_id}) when is_binary(job_id), do: job_id

  def existing_job_id(_existing_job), do: nil

  def step_terminal?(step),
    do: Map.get(step, "status") in @terminal_step_statuses

  def mark_step_running(step, agent_id, now) do
    step
    |> Map.put("status", "running")
    |> Map.put("started_at", Map.get(step, "started_at") || now)
    |> Map.put("last_event_at", now)
    |> Map.put("agent_ids", Enum.uniq(Map.get(step, "agent_ids", []) ++ [agent_id]))
  end

  def touch_step(step, now), do: Map.put(step, "last_event_at", now)

  def refresh_beacon(step, payload, now) do
    configured_timeout_ms =
      Map.get(payload, "timeout_ms") || Map.get(step, "beacon_timeout_ms")

    timeout_ms =
      Values.positive_int(
        configured_timeout_ms,
        Map.get(step, "beacon_timeout_ms")
      )

    heartbeat_deadline_at = Values.iso_after_ms_if_configured(now, timeout_ms)

    current =
      case Map.get(step, "current_attempt") do
        attempt when is_map(attempt) ->
          attempt
          |> Map.put("last_beacon_at", now)
          |> Map.put("heartbeat_deadline_at", heartbeat_deadline_at)

        other ->
          other
      end

    step
    |> Map.merge(%{
      "status" => "running",
      "last_event_at" => now,
      "heartbeat_deadline_at" => heartbeat_deadline_at,
      "current_attempt" => current
    })
  end

  def finish_current_attempt(step, status, now) do
    case Map.get(step, "current_attempt") do
      attempt when is_map(attempt) ->
        finished =
          attempt
          |> Map.put("status", status)
          |> Map.put("ended_at", now)

        step
        |> Map.update("attempts", [finished], &(&1 ++ [finished]))
        |> Map.put("current_attempt", nil)

      _ ->
        step
    end
  end

  def running_steps(%{"steps" => steps}) when is_map(steps) do
    steps
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, "status") in ["running", "retry_wait", "queued"]))
  end

  def running_steps(_state), do: []

  def get_step(%{"steps" => steps}, step_id) when is_map(steps), do: Map.get(steps, step_id)

  def get_step(_state, _step_id), do: nil

  def put_step(state, %{"id" => step_id} = step) do
    put_in(state, ["steps", step_id], step)
  end

  def put_state_status(state, status, now) do
    state
    |> Map.put("status", status)
    |> put_updated_at(now)
  end

  def put_updated_at(state, now), do: Map.put(state, "updated_at", now)

  def primary_agent_id(%{"agent_ids" => [agent_id | _]}), do: agent_id

  def primary_agent_id(_step), do: nil
end
