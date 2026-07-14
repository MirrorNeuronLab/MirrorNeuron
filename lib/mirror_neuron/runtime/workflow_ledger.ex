defmodule MirrorNeuron.Runtime.WorkflowLedger do
  @moduledoc false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.ErrorEnvelope
  alias MirrorNeuron.Runtime.WorkflowTrigger

  @schema_version 2
  @default_timeout_seconds 300
  @default_beacon_timeout_ms 45_000
  @default_retry_backoff_ms 1_000
  @default_max_scatter_items 1_000
  @successful_step_statuses ["completed", "partial", "skipped"]
  @terminal_step_statuses @successful_step_statuses ++ ["failed"]

  def new(manifest, runtime_nodes, existing_job \\ nil, job_id \\ nil) do
    definitions = step_definitions(manifest, runtime_nodes)

    if definitions == [] do
      disabled_state()
    else
      base = %{
        "schema_version" => @schema_version,
        "enabled" => true,
        "job_id" => job_id || existing_job_id(existing_job),
        "run_id" => existing_run_id(existing_job),
        "created_at" => Runtime.timestamp(),
        "updated_at" => Runtime.timestamp(),
        "status" => "pending",
        "step_order" => Enum.map(definitions, & &1["id"]),
        "agent_to_step" => build_agent_to_step(definitions),
        "edges" => graph_edges(manifest),
        "steps" => Map.new(definitions, &{&1["id"], initial_step(&1)}),
        "messages" => %{}
      }

      merge_existing(base, existing_job)
    end
  end

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

  def job_running(state, now \\ Runtime.timestamp()) do
    if enabled?(state) do
      {put_state_status(state, "running", now), []}
    else
      {state, []}
    end
  end

  def pause(state, now \\ Runtime.timestamp()) do
    if enabled?(state) do
      events =
        state
        |> running_steps()
        |> Enum.map(fn step ->
          workflow_event(:workflow_step_blocked, step, %{
            "reason" => "job paused",
            "blocked_at" => now
          })
        end)

      {put_state_status(state, "paused", now), events}
    else
      {state, []}
    end
  end

  def resume(state, now \\ Runtime.timestamp()) do
    if enabled?(state), do: {put_state_status(state, "running", now), []}, else: {state, []}
  end

  def finish(state, status, now \\ Runtime.timestamp()) do
    if enabled?(state), do: put_state_status(state, to_string(status), now), else: state
  end

  def decorate_message(state, agent_id, message, extra_headers \\ %{}) do
    if enabled?(state) do
      step_id = step_for_agent(state, agent_id)

      if step_id do
        step = get_step(state, step_id)
        decorate_step_message(state, step, message, extra_headers)
      else
        message
      end
    else
      message
    end
  end

  defp decorate_step_message(state, step, message, extra_headers \\ %{}) do
    headers =
      message
      |> Message.headers()
      |> Map.drop([
        "mn.workflow.step_id",
        "mn.workflow.attempt_id",
        "mn.workflow.attempt",
        "mn.workflow.deadline_at",
        "mn.workflow.heartbeat_deadline_at",
        "mn.workflow.idempotency_key"
      ])
      |> Map.merge(%{
        "mn.workflow.run_id" => run_id(state),
        "mn.workflow.step_id" => step["id"],
        "mn.workflow.timeout_seconds" => Map.get(step, "timeout_seconds"),
        "mn.workflow.heartbeat_timeout_ms" => Map.get(step, "beacon_timeout_ms")
      })
      |> Map.merge(stringify_map(extra_headers))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    put_in(message, ["headers"], headers)
  end

  def on_message_received(state, agent_id, message, now \\ Runtime.timestamp()) do
    with true <- enabled?(state),
         step_id when is_binary(step_id) <- step_id_for_message(state, agent_id, message),
         step when is_map(step) <- get_step(state, step_id) do
      cond do
        step_terminal?(step) ->
          ignore_duplicate_step_message(
            state,
            step,
            message,
            now,
            "workflow step already terminal"
          )

        not dependencies_satisfied?(state, step) ->
          block_step_for_dependencies(state, step, message, now)

        step_running_with_different_message?(step, message) ->
          ignore_duplicate_step_message(
            state,
            step,
            message,
            now,
            "workflow step already running"
          )

        not should_start_attempt?(step, message) ->
          {put_message_status(state, message, step_id, "running", now), []}

        true ->
          start_attempt(state, step, agent_id, message, now)
      end
    else
      _ -> {state, []}
    end
  end

  def on_message_acked(state, agent_id, message, now \\ Runtime.timestamp()) do
    with true <- enabled?(state),
         step_id when is_binary(step_id) <- step_id_for_message(state, agent_id, message) do
      {put_message_status(state, message, step_id, "acked", now), []}
    else
      _ -> {state, []}
    end
  end

  def on_agent_event(state, agent_id, event_type, payload, now \\ Runtime.timestamp()) do
    with true <- enabled?(state),
         step_id when is_binary(step_id) <- step_id_from_payload(state, agent_id, payload),
         step when is_map(step) <- get_step(state, step_id) do
      normalized_event_type = normalize_event_type(event_type)

      cond do
        step_terminal?(step) ->
          ignore_terminal_step_event(state, step, normalized_event_type, payload, now)

        true ->
          {next_state, events, actions} =
            handle_step_agent_event(state, agent_id, step, normalized_event_type, payload, now)

          activate_ready_steps(next_state, events, actions, now)
      end
    else
      _ -> {state, [], []}
    end
  end

  defp handle_step_agent_event(state, agent_id, step, event_type, payload, now) do
    case event_type do
      "agent_beacon" ->
        step = refresh_beacon(step, payload, now)
        state = put_step(state, step)
        {state, [workflow_event(:workflow_step_beacon, step, beacon_payload(payload, now))], []}

      "agent_beacon_missed" ->
        fail_current_attempt(state, step, "agent beacon deadline exceeded", now)

      "workflow_step_started" ->
        step = mark_step_running(step, agent_id, now)
        state = put_step(state, step)

        {state, [workflow_event(:workflow_step_attempt_started, step, %{"agent_id" => agent_id})],
         []}

      "workflow_step_completed" ->
        complete_step_if_ready(state, step, payload, now) |> without_actions()

      "workflow_step_partial" ->
        resolve_step(state, step, "partial", payload, now) |> without_actions()

      "workflow_step_skipped" ->
        {next_state, events} = resolve_step(state, step, "skipped", payload, now)

        {next_state, skip_events, skip_actions} =
          skip_downstream_steps(next_state, step, payload, now)

        {next_state, events ++ skip_events, skip_actions}

      "workflow_step_branch" ->
        apply_branch_selection(state, step, payload, now)

      "workflow_step_scatter" ->
        expand_scatter(state, step, payload, now)

      "workflow_step_failed" ->
        fail_current_attempt(
          state,
          step,
          stringify(payload["reason"] || payload["error"] || "step failed"),
          now
        )

      "workflow_step_attempt_completed" ->
        complete_step_if_ready(state, step, payload, now) |> without_actions()

      _other ->
        step = touch_step(step, now)
        {put_step(state, step), [], []}
    end
  end

  def on_agent_failed(state, agent_id, reason, now \\ Runtime.timestamp()) do
    with true <- enabled?(state),
         step_id when is_binary(step_id) <-
           active_step_for_agent(state, agent_id) || step_for_agent(state, agent_id),
         step when is_map(step) <- get_step(state, step_id) do
      if step_terminal?(step) do
        ignore_terminal_step_event(state, step, "agent_failed", %{"reason" => reason}, now)
      else
        {next_state, events, actions} = fail_current_attempt(state, step, stringify(reason), now)
        activate_ready_steps(next_state, events, actions, now)
      end
    else
      _ -> {state, [], []}
    end
  end

  def reconcile(state, now \\ Runtime.timestamp()) do
    if enabled?(state) and Map.get(state, "status") == "running" do
      state
      |> Map.get("step_order", [])
      |> Enum.reduce({state, [], []}, fn step_id, {acc_state, events, actions} ->
        step = get_step(acc_state, step_id)
        {next_state, next_events, next_actions} = reconcile_step(acc_state, step, now)
        {next_state, events ++ next_events, actions ++ next_actions}
      end)
    else
      {state, [], []}
    end
  end

  def mark_delivery_failed(state, message, step_id, reason, now \\ Runtime.timestamp()) do
    state =
      state
      |> put_message_status(message, step_id, "failed", now, %{"reason" => stringify(reason)})
      |> put_updated_at(now)

    event = %{
      type: :workflow_message_dead_lettered,
      step: step_id,
      message_id: safe_message_id(message),
      reason: stringify(reason),
      timestamp: now
    }

    {state, [event]}
  end

  defp reconcile_step(state, %{"status" => "running"} = step, now) do
    cond do
      expired?(Map.get(step, "deadline_at"), now) ->
        {state, events, actions} =
          fail_current_attempt(state, step, "workflow step deadline exceeded", now)

        {state,
         [
           workflow_event(:workflow_step_attempt_timed_out, step, %{
             "reason" => "deadline exceeded"
           })
           | events
         ],
         [{:terminate_agent, primary_agent_id(step), "workflow step deadline exceeded"} | actions]}

      expired?(Map.get(step, "heartbeat_deadline_at"), now) ->
        {state, events, actions} =
          fail_current_attempt(state, step, "workflow step heartbeat deadline exceeded", now)

        {state,
         [
           workflow_event(:workflow_step_attempt_timed_out, step, %{
             "reason" => "heartbeat deadline exceeded"
           })
           | events
         ],
         [
           {:terminate_agent, primary_agent_id(step), "workflow step heartbeat deadline exceeded"}
           | actions
         ]}

      true ->
        {state, [], []}
    end
  end

  defp reconcile_step(state, %{"status" => "retry_wait"} = step, now) do
    if expired?(Map.get(step, "retry_at"), now) do
      case retry_message(state, step, now) do
        {:ok, message, step} ->
          state = put_step(state, step)
          {state, [], [{:redeliver, step["id"], primary_agent_id(step), message}]}

        {:error, reason} ->
          state =
            put_step(
              state,
              Map.merge(step, %{
                "status" => "failed",
                "terminal_reason" => reason,
                "terminal_error" => step_error(reason, step)
              })
            )

          {state,
           [
             workflow_event(:workflow_step_failed, step, %{
               "reason" => reason,
               "error" => step_error(reason, step),
               "status" => "failed"
             })
           ], [{:fail_job, step["id"], reason}]}
      end
    else
      {state, [], []}
    end
  end

  defp reconcile_step(state, %{"status" => "blocked"} = step, now) do
    cond do
      dependencies_satisfied?(state, step) ->
        redeliver_or_trigger(state, step, now)

      dependencies_impossible?(state, step) ->
        skip_step(state, step, "trigger rule cannot be satisfied", now)

      true ->
        {state, [], []}
    end
  end

  defp reconcile_step(state, %{"status" => status} = step, now)
       when status in ["pending", "ready"] do
    cond do
      dependencies_impossible?(state, step) ->
        skip_step(state, step, "trigger rule cannot be satisfied", now)

      dependencies_satisfied?(state, step) and synthetic_trigger_required?(state, step) ->
        redeliver_or_trigger(state, step, now)

      dependencies_satisfied?(state, step) and is_map(Map.get(step, "last_message")) ->
        redeliver_or_trigger(state, step, now)

      true ->
        {state, [], []}
    end
  end

  defp reconcile_step(state, _step, _now), do: {state, [], []}

  defp activate_ready_steps(state, events, actions, now) do
    {next_state, ready_events, ready_actions} =
      state
      |> Map.get("step_order", [])
      |> Enum.reduce({state, [], []}, fn step_id, {acc_state, acc_events, acc_actions} ->
        step = get_step(acc_state, step_id)

        if is_map(step) and immediate_activation_required?(acc_state, step) do
          {updated_state, step_events, step_actions} = reconcile_step(acc_state, step, now)
          {updated_state, acc_events ++ step_events, acc_actions ++ step_actions}
        else
          {acc_state, acc_events, acc_actions}
        end
      end)

    {next_state, events ++ ready_events, actions ++ ready_actions}
  end

  defp immediate_activation_required?(state, step) do
    Map.get(step, "status") in ["pending", "ready", "blocked"] and
      (dependencies_impossible?(state, step) or
         (dependencies_satisfied?(state, step) and
            is_nil(Map.get(step, "last_message")) and
            synthetic_trigger_required?(state, step)))
  end

  defp redeliver_or_trigger(state, step, now) do
    case Map.get(step, "last_message") do
      message when is_map(message) ->
        step =
          step
          |> Map.merge(%{
            "status" => "queued",
            "last_event_at" => now,
            "terminal_reason" => nil,
            "terminal_error" => nil,
            "last_error" => nil
          })

        state = put_step(state, step) |> put_updated_at(now)
        {state, [], [{:redeliver, step["id"], primary_agent_id(step), message}]}

      _ ->
        trigger_message = synthetic_trigger_message(state, step, now)

        step =
          step
          |> Map.merge(%{
            "status" => "queued",
            "last_event_at" => now,
            "last_message" => trigger_message,
            "terminal_reason" => nil,
            "terminal_error" => nil,
            "last_error" => nil
          })

        state = put_step(state, step) |> put_updated_at(now)

        event =
          workflow_event(:workflow_step_triggered, step, %{"trigger_rule" => step["trigger_rule"]})

        {state, [event], [{:redeliver, step["id"], primary_agent_id(step), trigger_message}]}
    end
  end

  defp synthetic_trigger_required?(state, step) do
    rule = get_in(step, ["trigger_rule", "rule"])
    edges = incoming_edges(state, step)

    case rule do
      "one_failed" ->
        true

      "all_done" ->
        Enum.any?(edges, &dependency_failed?(state, &1))

      "one_done" ->
        Enum.any?(edges, fn edge ->
          dependency_terminal?(state, edge) and not dependency_success?(state, edge)
        end)

      _ ->
        false
    end
  end

  defp synthetic_trigger_message(state, step, now) do
    parents =
      state
      |> incoming_edges(step)
      |> Enum.map(fn edge ->
        parent = get_step(state, Map.get(edge, "from")) || %{}

        %{
          "step_id" => Map.get(edge, "from"),
          "status" => Map.get(parent, "status"),
          "outcome" => Map.get(parent, "terminal_outcome"),
          "output" => Map.get(parent, "output")
        }
      end)

    message =
      Message.new(
        Map.get(state, "job_id") || run_id(state),
        "workflow_ledger",
        primary_agent_id(step),
        "workflow_trigger",
        %{"trigger_rule" => step["trigger_rule"], "parents" => parents},
        timestamp: now,
        class: "command"
      )

    decorate_step_message(state, step, message)
  end

  defp apply_branch_selection(state, step, payload, now) do
    selected = selected_branch_ids(payload)

    candidates =
      state
      |> outgoing_edges(step["id"])
      |> Enum.map(&Map.get(&1, "to"))
      |> Enum.uniq()

    skipped = Enum.reject(candidates, &(&1 in selected))

    {next_state, skip_events, skip_actions} =
      Enum.reduce(skipped, {state, [], []}, fn step_id, {acc_state, events, actions} ->
        {next_state, next_events, next_actions} =
          skip_branch_path(acc_state, step_id, "not selected by branch #{step["id"]}", now)

        {next_state, events ++ next_events, actions ++ next_actions}
      end)

    event =
      workflow_event(:workflow_branch_selected, step, %{
        "selected" => selected,
        "skipped" => skipped
      })

    {next_state, [event | skip_events], skip_actions}
  end

  defp skip_downstream_steps(state, step, payload, now) do
    if Map.get(payload, "skip_downstream") == true do
      state
      |> descendant_step_ids(step["id"])
      |> Enum.reduce({state, [], []}, fn step_id, {acc_state, events, actions} ->
        case get_step(acc_state, step_id) do
          nil ->
            {acc_state, events, actions}

          descendant ->
            {next_state, next_events, next_actions} =
              skip_step(
                acc_state,
                descendant,
                "short-circuited by #{step["id"]}",
                now,
                terminate?: true
              )

            {next_state, events ++ next_events, actions ++ next_actions}
        end
      end)
    else
      {state, [], []}
    end
  end

  defp skip_branch_path(state, step_id, reason, now) do
    case get_step(state, step_id) do
      nil ->
        {state, [], []}

      step ->
        {state, events, actions} = skip_step(state, step, reason, now)

        {state, cascade_events, cascade_actions} =
          cascade_branch_skips(state, step_id, reason, now)

        {state, events ++ cascade_events, actions ++ cascade_actions}
    end
  end

  defp cascade_branch_skips(state, skipped_step_id, reason, now) do
    state
    |> outgoing_edges(skipped_step_id)
    |> Enum.map(&Map.get(&1, "to"))
    |> Enum.uniq()
    |> Enum.reduce({state, [], []}, fn child_id, {acc_state, events, actions} ->
      child = get_step(acc_state, child_id)

      if is_map(child) and not step_terminal?(child) and all_parents_skipped?(acc_state, child) do
        {next_state, next_events, next_actions} =
          skip_branch_path(acc_state, child_id, reason, now)

        {next_state, events ++ next_events, actions ++ next_actions}
      else
        {acc_state, events, actions}
      end
    end)
  end

  defp all_parents_skipped?(state, step) do
    case incoming_edges(state, step) do
      [] ->
        false

      edges ->
        Enum.all?(edges, fn edge ->
          get_in(state, ["steps", Map.get(edge, "from"), "status"]) == "skipped"
        end)
    end
  end

  defp skip_step(state, step, reason, now, opts \\ []) do
    if step_terminal?(step) do
      {state, [], []}
    else
      active? = Map.get(step, "status") in ["queued", "running", "retry_wait"]
      {next_state, events} = resolve_step(state, step, "skipped", %{"reason" => reason}, now)

      actions =
        if active? and Keyword.get(opts, :terminate?, false) do
          [{:terminate_agent, primary_agent_id(step), reason}]
        else
          []
        end

      {next_state, events, actions}
    end
  end

  defp expand_scatter(state, source_step, payload, now) do
    targets = scatter_targets(payload)
    items = Map.get(payload, "items")
    max_items = positive_int(Map.get(payload, "max_items"), @default_max_scatter_items)

    cond do
      targets == [] ->
        scatter_rejected(state, source_step, "scatter requires target or targets", now)

      not is_list(items) ->
        scatter_rejected(state, source_step, "scatter items must be a list", now)

      items == [] ->
        {state, [workflow_event(:workflow_step_scattered, source_step, %{"count" => 0})], []}

      length(items) > max_items ->
        scatter_rejected(state, source_step, "scatter item count exceeds #{max_items}", now)

      Enum.any?(targets, &(not is_map(get_step(state, &1)))) ->
        scatter_rejected(state, source_step, "scatter target does not name a workflow step", now)

      Enum.any?(targets, &step_terminal?(get_step(state, &1))) ->
        scatter_rejected(state, source_step, "scatter target is already terminal", now)

      true ->
        expand_scatter_items(state, source_step, targets, items, now)
    end
  end

  defp expand_scatter_items(state, source_step, targets, items, now) do
    instances =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        target = Enum.at(targets, rem(index, length(targets)))
        base = get_step(state, target)
        instance_id = "#{target}[#{index}]"

        %{
          "id" => instance_id,
          "target" => target,
          "item" => item,
          "step" =>
            initial_step(
              base
              |> Map.put("id", instance_id)
              |> Map.put("label", "#{base["label"]} [#{index}]")
              |> Map.put("map_index", index)
              |> Map.put("map_item", item)
            )
        }
      end)

    instance_ids_by_target = Enum.group_by(instances, & &1["target"], & &1["id"])
    target_steps = Enum.map(targets, &get_step(state, &1))

    {state, target_events} =
      Enum.reduce(target_steps, {state, []}, fn target, {acc_state, events} ->
        {next_state, next_events} =
          resolve_step(
            acc_state,
            target,
            "skipped",
            %{"reason" => "expanded into mapped work items"},
            now,
            outcome: "mapped"
          )

        {next_state, events ++ next_events}
      end)

    edges = expand_scatter_edges(state["edges"], instance_ids_by_target)

    mapped_steps =
      Map.new(instances, fn instance ->
        step = instance["step"]

        message =
          Message.new(
            Map.get(state, "job_id") || run_id(state),
            "workflow_ledger",
            primary_agent_id(step),
            "workflow_scatter_item",
            %{"item" => instance["item"], "map_index" => step["map_index"]},
            timestamp: now,
            class: "command"
          )
          |> then(&decorate_step_message(state, step, &1))

        {step["id"], Map.put(step, "last_message", message)}
      end)

    state =
      state
      |> Map.put("edges", edges)
      |> Map.update!("steps", fn steps ->
        Map.merge(steps, mapped_steps)
      end)
      |> Map.update!(
        "step_order",
        &(&1 ++ Enum.map(instances, fn instance -> instance["id"] end))
      )
      |> put_updated_at(now)

    event =
      workflow_event(:workflow_step_scattered, source_step, %{
        "count" => length(instances),
        "targets" => targets,
        "instance_ids" => Enum.map(instances, & &1["id"])
      })

    {state, [event | target_events], []}
  end

  defp scatter_rejected(state, step, reason, now) do
    step = touch_step(step, now)
    state = put_step(state, step) |> put_updated_at(now)
    {state, [workflow_event(:workflow_step_scatter_rejected, step, %{"reason" => reason})], []}
  end

  defp expand_scatter_edges(edges, instance_ids_by_target) do
    Enum.flat_map(edges, fn edge ->
      from_ids = Map.get(instance_ids_by_target, Map.get(edge, "from"), [Map.get(edge, "from")])
      to_ids = Map.get(instance_ids_by_target, Map.get(edge, "to"), [Map.get(edge, "to")])

      for from_id <- from_ids, to_id <- to_ids do
        edge
        |> Map.put("from", from_id)
        |> Map.put("to", to_id)
      end
    end)
  end

  defp scatter_targets(payload) do
    targets = Map.get(payload, "targets")

    values =
      cond do
        is_list(targets) -> targets
        is_binary(Map.get(payload, "target")) -> [Map.get(payload, "target")]
        true -> []
      end

    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp selected_branch_ids(payload) do
    values = Map.get(payload, "branches", Map.get(payload, "branch", []))

    values
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp outgoing_edges(%{"edges" => edges}, step_id) when is_list(edges) do
    Enum.filter(edges, &(Map.get(&1, "from") == step_id))
  end

  defp outgoing_edges(_state, _step_id), do: []

  defp descendant_step_ids(state, step_id) do
    descendants(state, MapSet.new([step_id]), [step_id])
    |> MapSet.delete(step_id)
    |> MapSet.to_list()
  end

  defp descendants(_state, seen, []), do: seen

  defp descendants(state, seen, [step_id | rest]) do
    next_ids =
      state
      |> outgoing_edges(step_id)
      |> Enum.map(&Map.get(&1, "to"))
      |> Enum.reject(&MapSet.member?(seen, &1))

    descendants(state, Enum.reduce(next_ids, seen, &MapSet.put(&2, &1)), rest ++ next_ids)
  end

  defp start_attempt(state, step, agent_id, message, now) do
    metadata = attempt_metadata(state, step, message, now)

    attempt = %{
      "attempt_id" => metadata.attempt_id,
      "attempt" => metadata.attempt_number,
      "agent_id" => agent_id,
      "message_id" => safe_message_id(message),
      "idempotency_key" => metadata.idempotency_key,
      "started_at" => now,
      "deadline_at" => metadata.deadline_at,
      "heartbeat_deadline_at" => metadata.heartbeat_deadline_at,
      "last_beacon_at" => now,
      "status" => "running"
    }

    decorated = decorate_message(state, agent_id, message, metadata.headers)

    step =
      step
      |> Map.merge(%{
        "status" => "running",
        "started_at" => Map.get(step, "started_at") || now,
        "ended_at" => nil,
        "last_event_at" => now,
        "attempt_count" => metadata.attempt_number,
        "current_attempt" => attempt,
        "deadline_at" => metadata.deadline_at,
        "heartbeat_deadline_at" => metadata.heartbeat_deadline_at,
        "retry_at" => nil,
        "last_message" => decorated,
        "terminal_reason" => nil,
        "terminal_error" => nil,
        "last_error" => nil
      })

    state =
      state
      |> put_step(step)
      |> put_message_status(decorated, step["id"], "running", now, %{
        "attempt_id" => metadata.attempt_id,
        "attempt" => metadata.attempt_number,
        "idempotency_key" => metadata.idempotency_key,
        "from" => Message.from(decorated),
        "to" => Message.to(decorated),
        "type" => Message.type(decorated)
      })
      |> put_updated_at(now)

    event =
      workflow_event(:workflow_step_attempt_started, step, %{
        "agent_id" => agent_id,
        "attempt_id" => metadata.attempt_id,
        "attempt" => metadata.attempt_number,
        "deadline_at" => metadata.deadline_at,
        "heartbeat_deadline_at" => metadata.heartbeat_deadline_at,
        "idempotency_key" => metadata.idempotency_key,
        "message_id" => safe_message_id(decorated)
      })

    {state, [event]}
  end

  defp fail_current_attempt(state, %{"current_attempt" => nil} = step, reason, now) do
    error = step_error(reason, step)

    step =
      Map.merge(step, %{
        "last_event_at" => now,
        "terminal_reason" => reason,
        "terminal_error" => error
      })

    state = put_step(state, step)
    {state, [], []}
  end

  defp fail_current_attempt(state, step, reason, now) do
    current = Map.get(step, "current_attempt") || %{}
    error = step_error(reason, step)

    finished_attempt =
      current
      |> Map.merge(%{
        "status" => "failed",
        "ended_at" => now,
        "reason" => reason,
        "error" => error
      })

    attempts = Map.get(step, "attempts", []) ++ [finished_attempt]
    step = Map.put(step, "attempts", attempts)
    attempt_count = Map.get(step, "attempt_count", length(attempts))

    cond do
      attempt_count < Map.get(step, "max_attempts", 1) ->
        retry_at = iso_after_ms(now, retry_delay_ms(step, attempt_count))

        step =
          step
          |> Map.merge(%{
            "status" => "retry_wait",
            "current_attempt" => nil,
            "deadline_at" => nil,
            "heartbeat_deadline_at" => nil,
            "retry_at" => retry_at,
            "last_event_at" => now,
            "terminal_reason" => reason,
            "last_error" => error
          })

        state = put_step(state, step) |> put_updated_at(now)

        event =
          workflow_event(:workflow_step_attempt_retry_scheduled, step, %{
            "reason" => reason,
            "error" => error,
            "retry_at" => retry_at,
            "next_attempt" => attempt_count + 1,
            "max_attempts" => Map.get(step, "max_attempts", 1)
          })

        {state, [event], []}

      optional_step?(step) ->
        status = optional_resolution_status(step)

        {state, events} =
          resolve_step(state, step, status, %{"reason" => reason}, now, outcome: "failed")

        failure_event =
          workflow_event(:workflow_step_failed, get_step(state, step["id"]), %{
            "reason" => reason,
            "error" => error,
            "status" => status,
            "handled" => true
          })

        {state, [failure_event | events], []}

      true ->
        step =
          step
          |> Map.merge(%{
            "status" => "failed",
            "current_attempt" => nil,
            "deadline_at" => nil,
            "heartbeat_deadline_at" => nil,
            "retry_at" => nil,
            "ended_at" => now,
            "last_event_at" => now,
            "terminal_reason" => reason,
            "terminal_error" => error
          })

        state = put_step(state, step) |> put_updated_at(now)

        event =
          workflow_event(:workflow_step_failed, step, %{
            "reason" => reason,
            "error" => error,
            "status" => "failed"
          })

        {state, [event], [{:fail_job, step["id"], reason}]}
    end
  end

  defp complete_step_if_ready(state, step, payload, now) do
    cond do
      stale_attempt_output?(step, payload) ->
        ignore_stale_step_output(state, step, payload, now)

      dependencies_satisfied?(state, step) ->
        complete_step(state, step, payload, now)

      true ->
        block_step_for_dependencies(state, step, Map.get(step, "last_message"), now)
    end
  end

  defp complete_step(state, step, payload, now) do
    step =
      finish_current_attempt(step, "completed", now)
      |> Map.merge(%{
        "status" => "completed",
        "ended_at" => now,
        "last_event_at" => now,
        "deadline_at" => nil,
        "heartbeat_deadline_at" => nil,
        "retry_at" => nil,
        "output" => payload,
        "terminal_outcome" => "success"
      })

    state = put_step(state, step) |> put_updated_at(now)
    {state, [workflow_event(:workflow_step_completed, step, %{"status" => "completed"})]}
  end

  defp resolve_step(state, step, status, payload, now, opts \\ []) do
    step =
      finish_current_attempt(step, status, now)
      |> Map.merge(%{
        "status" => status,
        "ended_at" => now,
        "last_event_at" => now,
        "deadline_at" => nil,
        "heartbeat_deadline_at" => nil,
        "retry_at" => nil,
        "output" => payload,
        "terminal_outcome" => Keyword.get(opts, :outcome, status)
      })

    state = put_step(state, step) |> put_updated_at(now)
    event_type = if status == "skipped", do: :workflow_step_skipped, else: :workflow_step_partial
    {state, [workflow_event(event_type, step, %{"status" => status})]}
  end

  defp without_actions({state, events}), do: {state, events, []}

  defp ignore_stale_step_output(state, step, payload, now) do
    step = touch_step(step, now)
    state = put_step(state, step) |> put_updated_at(now)

    event =
      workflow_event(:workflow_step_stale_output_ignored, step, %{
        "reason" => "attempt metadata does not match current attempt",
        "attempt_id" => payload_attempt_id(payload),
        "idempotency_key" => payload_idempotency_key(payload)
      })

    {state, [event]}
  end

  defp ignore_duplicate_step_message(state, step, message, now, reason) do
    step = touch_step(step, now)

    state =
      state
      |> put_step(step)
      |> put_message_status(message, step["id"], "ignored", now, %{
        "reason" => reason,
        "step_status" => Map.get(step, "status")
      })
      |> put_updated_at(now)

    event =
      workflow_event(:workflow_step_duplicate_message_ignored, step, %{
        "reason" => reason,
        "message_id" => safe_message_id(message),
        "step_status" => Map.get(step, "status")
      })

    {state, [event]}
  end

  defp ignore_terminal_step_event(state, step, event_type, payload, now) do
    step = touch_step(step, now)
    state = put_step(state, step) |> put_updated_at(now)

    event =
      workflow_event(:workflow_step_stale_event_ignored, step, %{
        "reason" => "workflow step already terminal",
        "event_type" => event_type,
        "step_status" => Map.get(step, "status"),
        "attempt_id" => payload_attempt_id(payload),
        "idempotency_key" => payload_idempotency_key(payload)
      })

    {state, [event], []}
  end

  defp block_step_for_dependencies(state, step, message, now) do
    reason = "waiting for workflow dependencies"

    step =
      step
      |> Map.merge(%{
        "status" => "blocked",
        "last_event_at" => now,
        "terminal_reason" => reason
      })
      |> maybe_put_last_message(message)

    state =
      state
      |> put_step(step)
      |> maybe_put_blocked_message_status(message, step["id"], now, reason)
      |> put_updated_at(now)

    event =
      workflow_event(:workflow_step_blocked, step, %{
        "reason" => reason,
        "blocked_on" => blocked_dependencies(state, step)
      })

    {state, [event]}
  end

  defp maybe_put_last_message(step, message) when is_map(message),
    do: Map.put(step, "last_message", message)

  defp maybe_put_last_message(step, _message), do: step

  defp stale_attempt_output?(step, payload) when is_map(payload) do
    current_attempt = Map.get(step, "current_attempt")
    payload_attempt_id = payload_attempt_id(payload)
    payload_idempotency_key = payload_idempotency_key(payload)

    cond do
      not is_map(current_attempt) ->
        false

      is_binary(payload_attempt_id) and
          payload_attempt_id != Map.get(current_attempt, "attempt_id") ->
        true

      is_binary(payload_idempotency_key) and
          payload_idempotency_key != Map.get(current_attempt, "idempotency_key") ->
        true

      true ->
        false
    end
  end

  defp stale_attempt_output?(_step, _payload), do: false

  defp payload_attempt_id(payload) when is_map(payload) do
    Map.get(payload, "attempt_id") || Map.get(payload, "mn.workflow.attempt_id")
  end

  defp payload_attempt_id(_payload), do: nil

  defp payload_idempotency_key(payload) when is_map(payload) do
    Map.get(payload, "idempotency_key") || Map.get(payload, "mn.workflow.idempotency_key")
  end

  defp payload_idempotency_key(_payload), do: nil

  defp maybe_put_blocked_message_status(state, message, step_id, now, reason)
       when is_map(message),
       do: put_message_status(state, message, step_id, "blocked", now, %{"reason" => reason})

  defp maybe_put_blocked_message_status(state, _message, _step_id, _now, _reason), do: state

  defp retry_message(state, step, now) do
    case Map.get(step, "last_message") do
      message when is_map(message) ->
        metadata = attempt_metadata(state, step, message, now)
        decorated = decorate_message(state, primary_agent_id(step), message, metadata.headers)

        step =
          step
          |> Map.merge(%{
            "status" => "queued",
            "retry_at" => nil,
            "last_event_at" => now,
            "last_message" => decorated
          })

        {:ok, decorated, step}

      _ ->
        {:error, "workflow retry has no saved message"}
    end
  end

  defp attempt_metadata(state, step, message, now) do
    attempt_number = Map.get(step, "attempt_count", 0) + 1
    attempt_id = attempt_id(step["id"], attempt_number)

    deadline_at =
      iso_after_seconds(now, Map.get(step, "timeout_seconds", @default_timeout_seconds))

    heartbeat_deadline_at =
      iso_after_ms(now, Map.get(step, "beacon_timeout_ms", @default_beacon_timeout_ms))

    idempotency_key = idempotency_key(state, step["id"], attempt_number, message)

    %{
      attempt_number: attempt_number,
      attempt_id: attempt_id,
      deadline_at: deadline_at,
      heartbeat_deadline_at: heartbeat_deadline_at,
      idempotency_key: idempotency_key,
      headers: %{
        "mn.workflow.attempt_id" => attempt_id,
        "mn.workflow.attempt" => attempt_number,
        "mn.workflow.deadline_at" => deadline_at,
        "mn.workflow.heartbeat_deadline_at" => heartbeat_deadline_at,
        "mn.workflow.idempotency_key" => idempotency_key
      }
    }
  end

  defp dependencies_satisfied?(state, step) do
    edges = incoming_edges(state, step)

    case Map.get(step, "trigger_rule", %{"rule" => "all_success"}) do
      %{"rule" => "all_success"} ->
        Enum.all?(edges, &dependency_satisfied?(state, &1))

      %{"rule" => "all_done"} ->
        Enum.all?(edges, &dependency_terminal?(state, &1))

      %{"rule" => "one_success"} ->
        Enum.any?(edges, &dependency_success?(state, &1))

      %{"rule" => "one_done"} ->
        Enum.any?(edges, &dependency_terminal?(state, &1))

      %{"rule" => "one_failed"} ->
        Enum.any?(edges, &dependency_failed?(state, &1))

      %{"rule" => "none_failed_min_one_success"} ->
        Enum.all?(edges, &dependency_terminal?(state, &1)) and
          not Enum.any?(edges, &dependency_failed?(state, &1)) and
          Enum.any?(edges, &dependency_success?(state, &1))

      %{"rule" => "quorum_success", "quorum" => quorum} ->
        Enum.count(edges, &dependency_success?(state, &1)) >= quorum

      _ ->
        Enum.all?(edges, &dependency_satisfied?(state, &1))
    end
  end

  defp dependencies_impossible?(state, step) do
    edges = incoming_edges(state, step)

    if edges == [] do
      false
    else
      all_terminal? = Enum.all?(edges, &dependency_terminal?(state, &1))

      case Map.get(step, "trigger_rule", %{"rule" => "all_success"}) do
        %{"rule" => "all_success"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "one_success"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "one_failed"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "none_failed_min_one_success"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "quorum_success", "quorum" => quorum} ->
          successes = Enum.count(edges, &dependency_success?(state, &1))
          pending = Enum.count(edges, &(not dependency_terminal?(state, &1)))
          successes + pending < quorum

        _ ->
          false
      end
    end
  end

  defp blocked_dependencies(state, step) do
    state
    |> incoming_edges(step)
    |> Enum.reject(&dependency_relevant?(state, step, &1))
    |> Enum.map(&blocked_dependency_summary(state, &1))
  end

  defp dependency_relevant?(state, step, edge) do
    case Map.get(step, "trigger_rule", %{"rule" => "all_success"}) do
      %{"rule" => "all_done"} -> dependency_terminal?(state, edge)
      %{"rule" => "one_success"} -> dependency_success?(state, edge)
      %{"rule" => "one_done"} -> dependency_terminal?(state, edge)
      %{"rule" => "one_failed"} -> dependency_failed?(state, edge)
      _ -> dependency_satisfied?(state, edge)
    end
  end

  defp dependency_satisfied?(state, edge) do
    case get_step(state, Map.get(edge, "from")) do
      nil -> true
      parent -> parent_status_accepted?(Map.get(parent, "status"), Map.get(edge, "accepts"))
    end
  end

  defp dependency_success?(state, edge) do
    case get_step(state, Map.get(edge, "from")) do
      nil ->
        true

      parent ->
        Map.get(parent, "terminal_outcome") == "success" or
          Map.get(parent, "status") == "completed"
    end
  end

  defp dependency_failed?(state, edge) do
    case get_step(state, Map.get(edge, "from")) do
      nil ->
        false

      parent ->
        Map.get(parent, "terminal_outcome") == "failed" or Map.get(parent, "status") == "failed"
    end
  end

  defp dependency_terminal?(state, edge) do
    case get_step(state, Map.get(edge, "from")) do
      nil -> true
      parent -> step_terminal?(parent)
    end
  end

  defp blocked_dependency_summary(state, edge) do
    parent = get_step(state, Map.get(edge, "from")) || %{}

    %{
      "from" => Map.get(edge, "from"),
      "status" => Map.get(parent, "status", "unknown"),
      "accepts" => normalized_accepts(Map.get(edge, "accepts")),
      "outcome" => Map.get(parent, "terminal_outcome")
    }
  end

  defp incoming_edges(%{"edges" => edges}, %{"id" => step_id}) when is_list(edges) do
    Enum.filter(edges, &(Map.get(&1, "to") == step_id))
  end

  defp incoming_edges(_state, _step), do: []

  defp parent_status_accepted?(status, accepts) do
    status in @successful_step_statuses and
      workflow_status_alias(status) in normalized_accepts(accepts)
  end

  defp workflow_status_alias("completed"), do: "done"
  defp workflow_status_alias(status), do: status

  defp normalized_accepts(accepts) when is_list(accepts) do
    accepts
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["done"]
      values -> values
    end
  end

  defp normalized_accepts(_accepts), do: ["done"]

  defp step_definitions(manifest, runtime_nodes) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    steps = Map.get(flow, "steps", [])
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    runtime_by_id = Map.new(runtime_nodes, &{&1.node_id, &1})

    if is_list(steps) do
      steps
      |> Enum.filter(&is_map/1)
      |> Enum.map(&step_definition(&1, runtime_by_id, graph))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp step_definition(raw, runtime_by_id, graph) do
    step_id = to_string(Map.get(raw, "id") || "")

    if step_id == "" do
      nil
    else
      run_id = to_string(Map.get(raw, "run") || step_id)
      configured_agent_id = to_string(Map.get(raw, "agent_id") || "")

      node =
        Map.get(runtime_by_id, configured_agent_id) ||
          Map.get(runtime_by_id, run_id) || Map.get(runtime_by_id, step_id)

      agent_id =
        cond do
          node -> node.node_id
          configured_agent_id != "" -> configured_agent_id
          true -> run_id
        end

      node_config = if node && is_map(node.config), do: node.config, else: %{}
      control = if is_map(Map.get(raw, "control")), do: Map.get(raw, "control"), else: %{}
      retry = if is_map(Map.get(control, "retry")), do: Map.get(control, "retry"), else: %{}

      timeout_seconds =
        positive_int(
          Map.get(control, "timeout_seconds") || Map.get(node_config, "timeout_seconds"),
          @default_timeout_seconds
        )

      # DockerWorker can report a terminal result but does not stream workflow
      # beacons while an LLM request is in flight.  Do not fail those valid
      # long-running steps at the generic 45-second beacon interval; their
      # declared workflow timeout remains the authoritative upper bound.
      beacon_timeout_ms =
        positive_int(
          Map.get(control, "beacon_timeout_ms") || Map.get(node_config, "beacon_timeout_ms"),
          timeout_seconds * 1_000
        )

      trigger_rule =
        case WorkflowTrigger.from_step(raw, graph) do
          {:ok, rule} -> rule
          {:error, _reason} -> %{"rule" => "all_success", "quorum" => nil}
        end

      %{
        "id" => step_id,
        "label" => to_string(Map.get(raw, "label") || step_id),
        "run" => run_id,
        "agent_ids" => [agent_id],
        "required" => Map.get(control, "required", true) != false,
        "failure_policy" => to_string(Map.get(control, "failure_policy") || "fail_workflow"),
        "trigger_rule" => trigger_rule,
        "max_attempts" =>
          positive_int(
            Map.get(retry, "max_attempts") || Map.get(control, "max_attempts") ||
              Map.get(node_config, "max_attempts"),
            1
          ),
        "retry_backoff_ms" =>
          retry_backoff_ms(
            Map.get(control, "retry_backoff_ms") || Map.get(node_config, "retry_backoff_ms"),
            Map.get(retry, "backoff_seconds")
          ),
        "retry_backoff_multiplier" => positive_number(Map.get(retry, "backoff_multiplier"), 2),
        "timeout_seconds" => timeout_seconds,
        "beacon_timeout_ms" => beacon_timeout_ms
      }
    end
  end

  defp initial_step(definition) do
    definition
    |> Map.merge(%{
      "status" => "pending",
      "attempt_count" => 0,
      "attempts" => [],
      "current_attempt" => nil,
      "deadline_at" => nil,
      "heartbeat_deadline_at" => nil,
      "retry_at" => nil,
      "started_at" => nil,
      "ended_at" => nil,
      "last_event_at" => nil,
      "terminal_reason" => nil,
      "terminal_error" => nil,
      "last_error" => nil,
      "last_message" => nil,
      "output" => nil,
      "terminal_outcome" => nil
    })
  end

  defp merge_existing(base, existing_job) when is_map(existing_job) do
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
              is_integer(Map.get(step, "map_index"))
          end)
          |> Map.new()

        steps = Map.merge(merged_base_steps, persisted_mapped_steps)

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
        |> Map.merge(Map.take(existing, ["created_at", "job_id", "run_id", "status", "messages"]))
        |> Map.put("steps", steps)
        |> Map.put("step_order", step_order)
        |> Map.put("edges", edges)
        |> Map.put("updated_at", Runtime.timestamp())

      _ ->
        base
    end
  end

  defp merge_existing(base, _existing_job), do: base

  defp existing_run_id(%{"workflow_state" => %{"run_id" => run_id}}) when is_binary(run_id),
    do: run_id

  defp existing_run_id(_existing_job), do: unique_id()

  defp existing_job_id(%{"job_id" => job_id}) when is_binary(job_id), do: job_id
  defp existing_job_id(_existing_job), do: nil

  defp build_agent_to_step(definitions) do
    definitions
    |> Enum.flat_map(fn definition ->
      Enum.map(definition["agent_ids"], &{&1, definition["id"]})
    end)
    |> Enum.reduce(%{}, fn {agent_id, step_id}, mapping ->
      Map.put_new(mapping, agent_id, step_id)
    end)
  end

  defp graph_edges(manifest) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    edges = Map.get(graph, "edges", [])

    if is_list(edges) do
      Enum.filter(edges, &is_map/1)
    else
      []
    end
  end

  defp step_id_for_message(state, agent_id, message) do
    headers = Message.headers(message)
    Map.get(headers, "mn.workflow.step_id") || step_for_agent(state, agent_id)
  end

  defp step_id_from_payload(state, agent_id, payload) when is_map(payload) do
    Map.get(payload, "step") ||
      Map.get(payload, "step_id") ||
      Map.get(payload, "workflow_step_id") ||
      Map.get(payload, "phase") ||
      Map.get(payload, "phase_id") ||
      active_step_for_agent(state, agent_id) || step_for_agent(state, agent_id)
  end

  defp step_id_from_payload(state, agent_id, _payload),
    do: active_step_for_agent(state, agent_id) || step_for_agent(state, agent_id)

  defp should_start_attempt?(step, _message) do
    not step_terminal?(step) and not is_map(Map.get(step, "current_attempt"))
  end

  defp step_terminal?(step),
    do: Map.get(step, "status") in @terminal_step_statuses

  defp step_running_with_different_message?(step, message) do
    current = Map.get(step, "current_attempt")

    Map.get(step, "status") == "running" and is_map(current) and
      Map.get(current, "message_id") != safe_message_id(message)
  end

  defp mark_step_running(step, agent_id, now) do
    step
    |> Map.put("status", "running")
    |> Map.put("started_at", Map.get(step, "started_at") || now)
    |> Map.put("last_event_at", now)
    |> Map.put("agent_ids", Enum.uniq(Map.get(step, "agent_ids", []) ++ [agent_id]))
  end

  defp touch_step(step, now), do: Map.put(step, "last_event_at", now)

  defp refresh_beacon(step, payload, now) do
    timeout_ms =
      positive_int(
        Map.get(payload, "timeout_ms") || Map.get(step, "beacon_timeout_ms"),
        @default_beacon_timeout_ms
      )

    current =
      case Map.get(step, "current_attempt") do
        attempt when is_map(attempt) ->
          attempt
          |> Map.put("last_beacon_at", now)
          |> Map.put("heartbeat_deadline_at", iso_after_ms(now, timeout_ms))

        other ->
          other
      end

    step
    |> Map.merge(%{
      "status" => "running",
      "last_event_at" => now,
      "heartbeat_deadline_at" => iso_after_ms(now, timeout_ms),
      "current_attempt" => current
    })
  end

  defp finish_current_attempt(step, status, now) do
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

  defp running_steps(%{"steps" => steps}) when is_map(steps) do
    steps
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, "status") in ["running", "retry_wait", "queued"]))
  end

  defp running_steps(_state), do: []

  defp get_step(%{"steps" => steps}, step_id) when is_map(steps), do: Map.get(steps, step_id)
  defp get_step(_state, _step_id), do: nil

  defp put_step(state, %{"id" => step_id} = step) do
    put_in(state, ["steps", step_id], step)
  end

  defp put_message_status(state, message, step_id, status, now, extra \\ %{}) do
    message_id = safe_message_id(message)

    if is_binary(message_id) do
      record =
        %{
          "message_id" => message_id,
          "step_id" => step_id,
          "status" => status,
          "updated_at" => now
        }
        |> Map.merge(extra)

      update_in(state, ["messages"], fn
        messages when is_map(messages) ->
          existing = Map.get(messages, message_id, %{})
          Map.put(messages, message_id, Map.merge(existing, record))

        _ ->
          %{message_id => record}
      end)
    else
      state
    end
  end

  defp put_state_status(state, status, now) do
    state
    |> Map.put("status", status)
    |> put_updated_at(now)
  end

  defp put_updated_at(state, now), do: Map.put(state, "updated_at", now)

  defp workflow_event(type, step, extra) do
    event =
      %{
        type: type,
        step: step["id"],
        step_id: step["id"],
        agent_id: primary_agent_id(step),
        attempt_id: get_in(step, ["current_attempt", "attempt_id"]),
        attempt: get_in(step, ["current_attempt", "attempt"]),
        status: step["status"],
        timestamp: Runtime.timestamp()
      }
      |> Map.merge(extra || %{})
      |> maybe_put_workflow_error(type, step)

    event
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_workflow_error(event, type, step) do
    cond do
      Map.get(event, "error") || Map.get(event, :error) ->
        event

      type in [
        :workflow_step_failed,
        :workflow_step_attempt_timed_out,
        :workflow_step_attempt_retry_scheduled,
        :workflow_message_dead_lettered
      ] ->
        reason =
          Map.get(event, "reason") ||
            Map.get(event, :reason) ||
            Map.get(step, "terminal_reason") ||
            "workflow step failed"

        Map.put(event, "error", step_error(reason, step, severity_for_workflow_event(type)))

      true ->
        event
    end
  end

  defp step_error(reason, step, opts \\ []) do
    current = Map.get(step, "current_attempt") || %{}
    attempt = Map.get(current, "attempt") || Map.get(step, "attempt_count")

    ErrorEnvelope.normalize(reason,
      component: "workflow_ledger",
      code: Keyword.get(opts, :code),
      severity: Keyword.get(opts, :severity, "ERROR"),
      retryable: Keyword.get(opts, :retryable),
      step_id: Map.get(step, "id"),
      agent_id: primary_agent_id(step),
      attempt: attempt,
      max_attempts: Map.get(step, "max_attempts")
    )
  end

  defp severity_for_workflow_event(:workflow_step_attempt_retry_scheduled),
    do: [severity: "WARN", retryable: true]

  defp severity_for_workflow_event(_type), do: []

  defp beacon_payload(payload, now) do
    %{
      "message" => payload["message"],
      "source" => payload["source"],
      "status" => payload["status"],
      "sequence" => payload["sequence"],
      "last_event_at" => now
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp optional_step?(step) do
    Map.get(step, "required") == false or
      Map.get(step, "failure_policy") in ["continue_partial", "skip", "continue"]
  end

  defp optional_resolution_status(%{"failure_policy" => "skip"}), do: "skipped"
  defp optional_resolution_status(_step), do: "partial"

  defp primary_agent_id(%{"agent_ids" => [agent_id | _]}), do: agent_id
  defp primary_agent_id(_step), do: nil

  defp retry_delay_ms(step, completed_attempt_count) do
    base = positive_int(Map.get(step, "retry_backoff_ms"), @default_retry_backoff_ms)
    multiplier = positive_number(Map.get(step, "retry_backoff_multiplier"), 2)
    trunc(base * :math.pow(multiplier, max(completed_attempt_count - 1, 0)))
  end

  defp retry_backoff_ms(value, _backoff_seconds) when is_integer(value) and value >= 0, do: value

  defp retry_backoff_ms(value, _backoff_seconds) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> @default_retry_backoff_ms
    end
  end

  defp retry_backoff_ms(_value, seconds) when is_integer(seconds) and seconds >= 0,
    do: seconds * 1000

  defp retry_backoff_ms(_value, seconds) when is_float(seconds) and seconds >= 0,
    do: trunc(seconds * 1000)

  defp retry_backoff_ms(_value, _seconds), do: @default_retry_backoff_ms

  defp idempotency_key(state, step_id, attempt, message) do
    [
      run_id(state),
      step_id,
      attempt,
      safe_message_id(message) || unique_id()
    ]
    |> Enum.join(":")
  end

  defp attempt_id(step_id, attempt), do: "#{step_id}:attempt:#{attempt}"

  defp safe_message_id(message) do
    Message.id(message)
  rescue
    _ -> nil
  end

  defp normalize_event_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_event_type(type), do: to_string(type)

  defp expired?(nil, _now), do: false

  defp expired?(iso, now) do
    case {parse_iso(iso), parse_iso(now)} do
      {{:ok, deadline}, {:ok, current}} -> DateTime.compare(current, deadline) != :lt
      _ -> false
    end
  end

  defp iso_after_seconds(now, seconds), do: iso_after_ms(now, positive_int(seconds, 0) * 1000)

  defp iso_after_ms(now, ms) do
    case parse_iso(now) do
      {:ok, datetime} ->
        datetime
        |> DateTime.add(positive_int(ms, 0), :millisecond)
        |> DateTime.truncate(:millisecond)
        |> DateTime.to_iso8601()

      _ ->
        Runtime.timestamp()
    end
  end

  defp parse_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_iso(_iso), do: :error

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(value, _default) when is_float(value) and value > 0, do: trunc(value)

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp positive_number(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_number(value, _default) when is_float(value) and value > 0, do: value
  defp positive_number(_value, default), do: default

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_map(_map), do: %{}

  defp unique_id do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
