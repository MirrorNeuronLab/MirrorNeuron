defmodule MirrorNeuron.Runtime.WorkflowLedger.Definitions do
  @moduledoc "Builds logical steps and templates from admitted runtime bindings."

  alias MirrorNeuron.Runtime.WorkflowActivity
  alias MirrorNeuron.Runtime.WorkflowLedger.Values
  alias MirrorNeuron.Runtime.WorkflowTrigger

  @default_timeout_seconds 300
  @default_retry_backoff_ms 1_000

  def step_definitions(manifest, runtime_nodes) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    steps = Map.get(flow, "steps", [])
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    runtime_by_id = Map.new(runtime_nodes, &{&1.node_id, &1})
    service_entrypoint_id = service_entrypoint_id(manifest, steps)

    if is_list(steps) do
      steps
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn step ->
        step_definition(
          step,
          runtime_by_id,
          graph,
          Map.get(step, "id") == service_entrypoint_id or WorkflowActivity.enabled?(flow),
          WorkflowActivity.enabled?(flow)
        )
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  def template_definitions(manifest, runtime_nodes) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    dynamic = if is_map(Map.get(flow, "dynamic")), do: Map.get(flow, "dynamic"), else: %{}
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    runtime_by_id = Map.new(runtime_nodes, &{&1.node_id, &1})

    child_templates =
      flow
      |> Map.get("child_workflows", %{})
      |> Map.values()
      |> Enum.flat_map(&normalize_template_specs(&1["templates"]))

    (normalize_template_specs(Map.get(dynamic, "templates", %{})) ++ child_templates)
    |> Enum.map(
      &step_definition(
        &1,
        runtime_by_id,
        graph,
        WorkflowActivity.enabled?(flow),
        WorkflowActivity.enabled?(flow)
      )
    )
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_template_specs(templates) when is_map(templates) do
    Enum.map(templates, fn {template_id, spec} ->
      if is_map(spec),
        do: Map.put_new(spec, "id", to_string(template_id)),
        else: %{"id" => to_string(template_id)}
    end)
  end

  defp normalize_template_specs(templates) when is_list(templates),
    do: Enum.filter(templates, &is_map/1)

  defp normalize_template_specs(_templates), do: []

  defp step_definition(raw, runtime_by_id, graph, unbounded_by_default?, activity?) do
    step_id = to_string(Map.get(raw, "id") || "")

    if step_id == "" do
      nil
    else
      run_id = MirrorNeuron.Manifest.workflow_step_run_id(raw)
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

      agent_ids =
        raw
        |> Map.get("agent_ids", [])
        |> case do
          values when is_list(values) ->
            values
            |> Enum.map(&to_string/1)
            |> Enum.reject(&(&1 == ""))
            |> then(fn normalized -> if normalized == [], do: [agent_id], else: normalized end)

          _ ->
            [agent_id]
        end

      node_config = if node && is_map(node.config), do: node.config, else: %{}
      control = if is_map(Map.get(raw, "control")), do: Map.get(raw, "control"), else: %{}
      retry = if is_map(Map.get(control, "retry")), do: Map.get(control, "retry"), else: %{}

      configured_timeout_seconds =
        Map.get(control, "timeout_seconds") || Map.get(node_config, "timeout_seconds")

      timeout_seconds =
        if unbounded_by_default? and is_nil(configured_timeout_seconds) do
          nil
        else
          Values.positive_int(configured_timeout_seconds, @default_timeout_seconds)
        end

      # A runner's inherited defaults do not create a second workflow liveness
      # contract. Docker/OpenShell relay SDK progress live; explicit workflow
      # heartbeat controls remain authoritative alongside soft inspection.
      node_beacon_timeout_ms =
        if Map.get(node_config, "runner_module") in [
             "MirrorNeuron.Runner.DockerWorker",
             "MirrorNeuron.Runner.OpenShell"
           ],
           do: nil,
           else: Map.get(node_config, "beacon_timeout_ms")

      configured_beacon_timeout_ms =
        Map.get(control, "beacon_timeout_ms") || node_beacon_timeout_ms

      beacon_timeout_ms =
        cond do
          not is_nil(configured_beacon_timeout_ms) ->
            Values.positive_int(
              configured_beacon_timeout_ms,
              (timeout_seconds || @default_timeout_seconds) * 1_000
            )

          activity? ->
            45_000

          is_nil(timeout_seconds) ->
            nil

          true ->
            timeout_seconds * 1_000
        end

      trigger_rule =
        case WorkflowTrigger.from_step(raw, graph) do
          {:ok, rule} -> rule
          {:error, _reason} -> %{"rule" => "all_success", "quorum" => nil}
        end

      %{
        "id" => step_id,
        "label" => to_string(Map.get(raw, "label") || step_id),
        "run" => run_id,
        "agent_ids" => agent_ids,
        "input_agent_id" =>
          if(
            node &&
              (Map.get(node, :agent_type) == "step_source" or Map.get(node, :type) == "stream" or
                 Map.get(node_config, "workflow_complete_step", true) == false),
            do: agent_id
          ),
        "required" => Map.get(control, "required", true) != false,
        "failure_policy" => to_string(Map.get(control, "failure_policy") || "fail_workflow"),
        "trigger_rule" => trigger_rule,
        "max_attempts" =>
          Values.positive_int(
            Map.get(retry, "max_attempts") || Map.get(control, "max_attempts") ||
              Map.get(node_config, "max_attempts"),
            1
          ),
        "retry_backoff_ms" =>
          retry_backoff_ms(
            Map.get(control, "retry_backoff_ms") || Map.get(node_config, "retry_backoff_ms"),
            Map.get(retry, "backoff_seconds")
          ),
        "retry_backoff_multiplier" =>
          Values.positive_number(Map.get(retry, "backoff_multiplier"), 2),
        "supervision" => if(activity?, do: "activity"),
        "timeout_seconds" => timeout_seconds,
        "beacon_timeout_ms" => beacon_timeout_ms,
        "heartbeat_uses_execution_budget" =>
          is_nil(configured_beacon_timeout_ms) and not activity?
      }
    end
  end

  def initial_step(definition) do
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

  defp service_entrypoint_id(%{type: "service", flow: flow}, steps)
       when is_map(flow) and is_list(steps) do
    Map.get(flow, "entrypoint") ||
      Map.get(flow, "source") ||
      Enum.find_value(steps, fn
        %{"id" => step_id} when is_binary(step_id) and step_id != "" -> step_id
        _ -> nil
      end)
  end

  defp service_entrypoint_id(_manifest, _steps), do: nil

  def build_agent_to_step(definitions) do
    definitions
    |> Enum.flat_map(fn definition ->
      Enum.map(definition["agent_ids"], &{&1, definition["id"]})
    end)
    |> Enum.reduce(%{}, fn {agent_id, step_id}, mapping ->
      Map.put_new(mapping, agent_id, step_id)
    end)
  end

  def graph_edges(manifest) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    edges = Map.get(graph, "edges", [])

    if is_list(edges) do
      Enum.filter(edges, &is_map/1)
    else
      []
    end
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
end
