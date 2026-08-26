defmodule MirrorNeuron.Manifest do
  @api_version "mn.workflow/v1"

  defstruct [
    :api_version,
    :kind,
    :manifest_version,
    :graph_id,
    :job_name,
    :type,
    :contract,
    :flow,
    :runtime,
    :required_context_engine,
    :requirements,
    :skill_dependencies,
    :input_validation,
    :services,
    :required_services,
    :deployment,
    :schedule,
    :triggers,
    :parameterized,
    :response_service,
    :metadata,
    :nodes,
    :edges,
    :policies,
    :entrypoints,
    :initial_inputs,
    :reload,
    :extensions
  ]

  alias MirrorNeuron.{AgentRegistry, AgentTemplates, ResourceSpec}
  alias MirrorNeuron.Runner.Policy, as: RunnerPolicy
  alias MirrorNeuron.ServiceSpec

  alias MirrorNeuron.Runtime.{
    DeploymentPolicy,
    DynamicWorkflowSpec,
    LifecyclePolicy,
    RouteCondition,
    SchedulePolicy,
    WorkflowTrigger
  }

  @known_top_level_keys MapSet.new([
                          "apiVersion",
                          "kind",
                          "manifest_version",
                          "graph_id",
                          "job_name",
                          "type",
                          "contract",
                          "flow",
                          "runtime",
                          "required_context_engine",
                          "requirements",
                          "skill_dependencies",
                          "input_validation",
                          "services",
                          "required_services",
                          "deployment",
                          "schedule",
                          "triggers",
                          "parameterized",
                          "response_service",
                          "metadata",
                          "nodes",
                          "edges",
                          "policies",
                          "entrypoints",
                          "initial_inputs",
                          "reload"
                        ])

  def load(%__MODULE__{} = manifest), do: {:ok, manifest}

  def load(path) when is_binary(path) do
    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, decoded} <- Jason.decode(raw) do
        normalize_and_validate(decoded)
      else
        {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
        {:error, reason} -> {:error, "failed to load manifest: #{inspect(reason)}"}
      end
    else
      case Jason.decode(path) do
        {:ok, decoded} -> normalize_and_validate(decoded)
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end

  def load(map) when is_map(map), do: normalize_and_validate(map)

  def topology(%__MODULE__{} = manifest) do
    %{
      "nodes" =>
        Enum.map(manifest.nodes, fn node ->
          %{
            "node_id" => node.node_id,
            "agent_type" => node.agent_type,
            "type" => node.type,
            "role" => node.role
          }
        end),
      "edges" =>
        Enum.map(manifest.edges, fn edge ->
          %{
            "edge_id" => edge.edge_id,
            "from_node" => edge.from_node,
            "to_node" => edge.to_node,
            "message_type" => edge.message_type,
            "routing_mode" => edge.routing_mode,
            "conditions" => json_safe(edge.conditions)
          }
        end)
    }
  end

  def to_map(%__MODULE__{} = manifest) do
    json_safe(manifest.extensions || %{})
    |> maybe_put("apiVersion", manifest.api_version)
    |> maybe_put("kind", manifest.kind)
    |> Map.merge(%{
      "manifest_version" => manifest.manifest_version,
      "type" => manifest.type,
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "required_context_engine" => manifest.required_context_engine,
      "requirements" => json_safe(manifest.requirements),
      "skill_dependencies" => json_safe(manifest.skill_dependencies),
      "input_validation" => json_safe(manifest.input_validation),
      "services" => json_safe(manifest.services),
      "required_services" => json_safe(manifest.required_services),
      "deployment" => json_safe(manifest.deployment),
      "schedule" => json_safe(manifest.schedule),
      "triggers" => json_safe(manifest.triggers),
      "parameterized" => json_safe(manifest.parameterized),
      "response_service" => json_safe(manifest.response_service),
      "metadata" => json_safe(manifest.metadata),
      "policies" => json_safe(manifest.policies),
      "entrypoints" => manifest.entrypoints,
      "initial_inputs" => json_safe(manifest.initial_inputs),
      "reload" => json_safe(manifest.reload)
    })
    |> maybe_put("contract", manifest.contract)
    |> maybe_put("flow", flow_to_map(manifest))
    |> maybe_put("runtime", manifest.runtime)
  end

  defp normalize_and_validate(raw) do
    raw_nodes = raw_nodes(raw)
    raw_edges = raw_edges(raw)

    manifest = %__MODULE__{
      api_version: Map.get(raw, "apiVersion"),
      kind: Map.get(raw, "kind"),
      manifest_version: Map.get(raw, "manifest_version"),
      type: normalize_type(Map.get(raw, "type")),
      graph_id: Map.get(raw, "graph_id"),
      job_name: Map.get(raw, "job_name") || Map.get(raw, "graph_id"),
      contract: normalize_optional_map(Map.get(raw, "contract")),
      flow: normalize_optional_map(Map.get(raw, "flow")),
      runtime: normalize_optional_map(Map.get(raw, "runtime")),
      required_context_engine:
        normalize_required_context_engine(Map.get(raw, "required_context_engine", false)),
      requirements: Map.get(raw, "requirements", %{}),
      skill_dependencies: normalize_optional_list(Map.get(raw, "skill_dependencies", [])),
      input_validation: Map.get(raw, "input_validation", %{}),
      services: ServiceSpec.normalize_services(Map.get(raw, "services", [])),
      required_services:
        ServiceSpec.normalize_required_services(Map.get(raw, "required_services", [])),
      deployment: normalize_deployment(Map.get(raw, "deployment", %{})),
      schedule: normalize_schedule(Map.get(raw, "schedule", %{})),
      triggers: normalize_triggers(Map.get(raw, "triggers", [])),
      parameterized: normalize_parameterized(Map.get(raw, "parameterized", %{})),
      response_service: normalize_response_service(Map.get(raw, "response_service")),
      metadata: Map.get(raw, "metadata", %{}),
      nodes: Enum.map(raw_nodes, &normalize_node/1),
      edges: Enum.map(raw_edges, &normalize_edge/1),
      policies: normalize_policies(Map.get(raw, "policies", %{})),
      entrypoints: normalize_entrypoints(Map.get(raw, "entrypoints"), raw_nodes),
      initial_inputs: normalize_initial_inputs(Map.get(raw, "initial_inputs", %{})),
      reload: normalize_reload(Map.get(raw, "reload", %{})),
      extensions: extension_fields(raw)
    }

    retired_errors = retired_manifest_errors(raw)

    case {retired_errors, validate(manifest)} do
      {[], :ok} -> {:ok, manifest}
      {errors, :ok} -> {:error, Enum.reverse(errors)}
      {[], {:error, errors}} -> {:error, errors}
      {retired_errors, {:error, errors}} -> {:error, errors ++ Enum.reverse(retired_errors)}
    end
  end

  defp raw_nodes(raw) do
    flow_nodes = get_in(raw, ["flow", "nodes"])

    cond do
      is_list(flow_nodes) -> flow_nodes
      true -> []
    end
  end

  defp raw_edges(raw) do
    flow_edges = get_in(raw, ["flow", "edges"])

    cond do
      is_list(flow_edges) -> flow_edges
      true -> []
    end
  end

  defp retired_manifest_errors(raw) do
    []
    |> maybe_collect_error(
      Map.has_key?(raw, "nodes"),
      "top-level nodes is no longer supported; use flow.nodes"
    )
    |> maybe_collect_error(
      Map.has_key?(raw, "edges"),
      "top-level edges is no longer supported; use flow.edges"
    )
    |> maybe_collect_error(
      Map.has_key?(raw, "daemon"),
      "daemon is no longer supported; use type service"
    )
    |> maybe_collect_error(Map.has_key?(raw, "requirments"), "use requirements")
    |> maybe_collect_error(Map.has_key?(raw, "inputValidation"), "use input_validation")
    |> maybe_collect_error(Map.has_key?(raw, "requiredServices"), "use required_services")
    |> maybe_collect_error(
      Map.has_key?(raw, "requiredContextEngine"),
      "use required_context_engine"
    )
  end

  def validate(%__MODULE__{} = manifest) do
    errors =
      []
      |> validate_required(manifest)
      |> validate_nodes(manifest)
      |> validate_edges(manifest)
      |> validate_workflow_flow(manifest)
      |> validate_entrypoints(manifest)
      |> validate_type(manifest)
      |> validate_required_context_engine(manifest)
      |> validate_requirements(manifest)
      |> validate_input_validation(manifest)
      |> validate_services(manifest)
      |> validate_deployment(manifest)
      |> validate_schedule(manifest)
      |> validate_response_service(manifest)
      |> validate_completion_contract(manifest)
      |> validate_policies(manifest)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_required(errors, manifest) do
    errors
    |> maybe_add_error(
      manifest.api_version != @api_version,
      "apiVersion must be #{@api_version}"
    )
    |> maybe_add_error(manifest.kind != "Workflow", "kind must be Workflow")
    |> maybe_add_error(is_nil(manifest.manifest_version), "manifest_version is required")
    |> maybe_add_error(
      not nonempty_string?(manifest.graph_id),
      "graph_id must be a non-empty string"
    )
    |> maybe_add_error(
      not nonempty_string?(manifest.job_name),
      "job_name must be a non-empty string"
    )
    |> maybe_add_error(manifest.nodes == [], "nodes must not be empty")
  end

  defp validate_nodes(errors, manifest) do
    node_ids = Enum.map(manifest.nodes, & &1.node_id)
    duplicates = node_ids -- Enum.uniq(node_ids)

    unsupported =
      manifest.nodes
      |> Enum.reject(&AgentRegistry.supported_type?(&1.agent_type))
      |> Enum.map(&"unsupported agent_type #{inspect(&1.agent_type)} for node #{&1.node_id}")

    unsupported_templates =
      manifest.nodes
      |> Enum.reject(&AgentTemplates.supported_type?(&1.type))
      |> Enum.map(&"unsupported template type #{inspect(&1.type)} for node #{&1.node_id}")

    incompatible_templates =
      manifest.nodes
      |> Enum.reject(&AgentTemplates.supported_for_agent_type?(&1.type, &1.agent_type))
      |> Enum.map(
        &"template type #{inspect(&1.type)} is not supported for agent_type #{inspect(&1.agent_type)} on node #{&1.node_id}"
      )

    empty_ids =
      manifest.nodes
      |> Enum.filter(&(is_nil(&1.node_id) or &1.node_id == ""))
      |> Enum.map(fn _ -> "node_id is required for every node" end)

    errors
    |> add_errors(Enum.map(Enum.uniq(duplicates), &"duplicate node_id #{&1}"))
    |> add_errors(unsupported)
    |> add_errors(unsupported_templates)
    |> add_errors(incompatible_templates)
    |> add_errors(empty_ids)
  end

  defp validate_edges(errors, manifest) do
    node_ids = MapSet.new(Enum.map(manifest.nodes, & &1.node_id))

    edge_errors =
      Enum.flat_map(manifest.edges, fn edge ->
        []
        |> maybe_collect_error(
          not MapSet.member?(node_ids, edge.from_node),
          "edge #{edge.edge_id || "unknown"} references missing from_node #{edge.from_node}"
        )
        |> maybe_collect_error(
          not MapSet.member?(node_ids, edge.to_node),
          "edge #{edge.edge_id || "unknown"} references missing to_node #{edge.to_node}"
        )
        |> maybe_collect_error(
          is_nil(edge.message_type) or edge.message_type == "",
          "edge #{edge.edge_id || "unknown"} must define message_type"
        )
        |> maybe_collect_error(
          edge.routing_mode not in RouteCondition.supported_routing_modes(),
          "edge #{edge.edge_id || "unknown"} has unsupported routing_mode #{inspect(edge.routing_mode)}"
        )
        |> add_condition_error(edge)
      end)

    add_errors(errors, edge_errors)
  end

  defp validate_workflow_flow(errors, manifest) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    steps = Map.get(flow, "steps", [])
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    graph_edges = Map.get(graph, "edges", [])

    if is_list(steps) and steps != [] do
      step_ids =
        steps
        |> Enum.filter(&is_map/1)
        |> Enum.map(&(Map.get(&1, "id") |> to_string()))

      duplicate_ids = step_ids -- Enum.uniq(step_ids)
      valid_ids = MapSet.new(Enum.reject(step_ids, &(&1 == "")))

      step_errors =
        steps
        |> Enum.filter(&is_map/1)
        |> Enum.flat_map(fn step ->
          step_id = Map.get(step, "id") |> to_string()

          case WorkflowTrigger.from_step(step, graph) do
            {:ok, %{"rule" => "quorum_success", "quorum" => quorum}} ->
              incoming_count =
                graph_edges
                |> List.wrap()
                |> Enum.count(&(is_map(&1) and Map.get(&1, "to") == step_id))

              []
              |> maybe_collect_error(step_id == "", "workflow step id is required")
              |> maybe_collect_error(
                incoming_count > 0 and quorum > incoming_count,
                "workflow step #{step_id} quorum #{quorum} exceeds its #{incoming_count} upstream steps"
              )

            {:ok, _trigger} ->
              maybe_collect_error([], step_id == "", "workflow step id is required")

            {:error, reason} ->
              ["workflow step #{step_id || "unknown"} has invalid trigger rule: #{reason}"]
          end
        end)

      graph_errors =
        graph_edges
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.flat_map(fn edge ->
          from = to_string(Map.get(edge, "from") || "")
          to = to_string(Map.get(edge, "to") || "")

          []
          |> maybe_collect_error(
            not MapSet.member?(valid_ids, from),
            "workflow edge references missing from step #{from}"
          )
          |> maybe_collect_error(
            not MapSet.member?(valid_ids, to),
            "workflow edge references missing to step #{to}"
          )
          |> maybe_collect_error(
            from == to and from != "",
            "workflow edge cannot point from #{from} to itself"
          )
        end)

      cycle_errors =
        if graph_errors == [] and
             workflow_cycle?(MapSet.to_list(valid_ids), List.wrap(graph_edges)) do
          ["workflow graph must be acyclic"]
        else
          []
        end

      dynamic_errors =
        DynamicWorkflowSpec.validation_errors(
          flow,
          Enum.map(manifest.nodes, & &1.node_id)
        )

      errors
      |> add_errors(Enum.map(Enum.uniq(duplicate_ids), &"duplicate workflow step id #{&1}"))
      |> add_errors(step_errors)
      |> add_errors(graph_errors)
      |> add_errors(cycle_errors)
      |> add_errors(dynamic_errors)
    else
      errors
    end
  end

  defp workflow_cycle?(step_ids, edges) do
    parents = Map.new(step_ids, &{&1, MapSet.new()})

    parents =
      Enum.reduce(edges, parents, fn edge, acc ->
        from = to_string(Map.get(edge, "from") || "")
        to = to_string(Map.get(edge, "to") || "")

        if Map.has_key?(acc, from) and Map.has_key?(acc, to) do
          Map.update!(acc, to, &MapSet.put(&1, from))
        else
          acc
        end
      end)

    do_workflow_cycle?(parents, [])
  end

  defp do_workflow_cycle?(parents, removed) do
    ready =
      parents
      |> Enum.reject(fn {step_id, _parents} -> step_id in removed end)
      |> Enum.filter(fn {_step_id, dependencies} ->
        MapSet.subset?(dependencies, MapSet.new(removed))
      end)
      |> Enum.map(&elem(&1, 0))

    case ready do
      [] ->
        map_size(parents) != length(removed)

      _ ->
        do_workflow_cycle?(parents, Enum.uniq(removed ++ ready))
    end
  end

  defp validate_completion_contract(errors, manifest) do
    step_runs = workflow_step_run_ids(manifest)
    outgoing = outgoing_edge_counts(manifest)

    completion_errors =
      Enum.flat_map(manifest.nodes, fn node ->
        config = if is_map(node.config), do: node.config, else: %{}
        terminal_sink? = Map.get(config, "terminal_sink") == true
        complete_run? = Map.get(config, "complete_run") == true
        complete_on_message? = Map.get(config, "complete_on_message") == true
        complete_after? = completion_threshold?(Map.get(config, "complete_after"))
        output_message_type = Map.get(config, "output_message_type")

        []
        |> maybe_collect_error(
          contains_completion_key?(config, "complete_job"),
          "node #{node.node_id} config uses unsupported complete_job; use complete_run or complete_step"
        )
        |> maybe_collect_error(
          contains_completion_key?(config, "complete_job?"),
          "node #{node.node_id} config uses unsupported complete_job?; use complete_run or complete_step"
        )
        |> maybe_collect_error(
          complete_on_message? and not valid_output_message_type?(output_message_type) and
            not (terminal_sink? and complete_run?),
          "node #{node.node_id} complete_on_message requires output_message_type or terminal_sink with complete_run"
        )
        |> maybe_collect_error(
          complete_after? and not valid_output_message_type?(output_message_type) and
            not (terminal_sink? and complete_run?),
          "node #{node.node_id} complete_after requires output_message_type or terminal_sink with complete_run"
        )
        |> maybe_collect_error(
          MapSet.member?(step_runs, node.node_id) and complete_run?,
          "workflow step node #{node.node_id} cannot declare complete_run"
        )
        |> maybe_collect_error(
          terminal_sink? and Map.get(outgoing, node.node_id, 0) > 0,
          "terminal sink #{node.node_id} must not have outgoing edges"
        )
      end)

    add_errors(errors, completion_errors)
  end

  defp add_condition_error(errors, edge) do
    case RouteCondition.validate(edge.conditions) do
      :ok ->
        errors

      {:error, reason} ->
        ["edge #{edge.edge_id || "unknown"} has invalid conditions: #{reason}" | errors]
    end
  end

  defp validate_entrypoints(errors, manifest) do
    node_ids = MapSet.new(Enum.map(manifest.nodes, & &1.node_id))

    entrypoint_errors =
      manifest.entrypoints
      |> Enum.reject(&MapSet.member?(node_ids, &1))
      |> Enum.map(&"entrypoint #{&1} does not reference a known node")

    maybe_add_default_entrypoint_error(errors, manifest, entrypoint_errors)
  end

  defp maybe_add_default_entrypoint_error(errors, manifest, entrypoint_errors) do
    root_roles =
      manifest.nodes
      |> Enum.filter(&(&1.role in ["root", "root_coordinator"]))

    errors =
      if manifest.entrypoints == [] and root_roles == [] do
        [
          "manifest must define at least one entrypoint or one node with role root/root_coordinator"
          | errors
        ]
      else
        errors
      end

    add_errors(errors, entrypoint_errors)
  end

  defp validate_policies(errors, manifest) do
    supported_recovery_modes = Application.get_env(:mirror_neuron, :supported_recovery_modes, [])
    policies = manifest.policies
    recovery_mode = if is_map(policies), do: Map.get(policies, "recovery_mode", "auto")

    errors
    |> maybe_add_error(not is_map(policies), "policies must be an object")
    |> maybe_add_error(
      is_map(policies) and recovery_mode not in supported_recovery_modes,
      "unsupported recovery_mode #{inspect(recovery_mode)}"
    )
    |> validate_scheduler_policy(manifest)
    |> validate_node_scheduling(manifest)
    |> add_errors(ResourceSpec.validate_manifest(manifest))
    |> add_errors(RunnerPolicy.validate_manifest(manifest))
    |> add_errors(LifecyclePolicy.validate_manifest(manifest))
  end

  defp validate_scheduler_policy(errors, %{policies: policies})
       when is_map(policies) do
    job_type =
      Map.get(policies, "job_type") ||
        get_in(policies, ["scheduler", "job_type"])

    strategy =
      Map.get(policies, "scheduler_strategy") ||
        get_in(policies, ["scheduler", "strategy"])

    errors
    |> maybe_add_error(
      not is_nil(job_type) and
        String.downcase(to_string(job_type)) not in MirrorNeuron.Scheduler.supported_job_types(),
      "unsupported job_type #{inspect(job_type)}"
    )
    |> maybe_add_error(
      not is_nil(strategy) and
        String.downcase(to_string(strategy)) not in MirrorNeuron.Scheduler.supported_strategies(),
      "unsupported scheduler strategy #{inspect(strategy)}"
    )
  end

  defp validate_scheduler_policy(errors, _manifest), do: errors

  defp validate_node_scheduling(errors, manifest) do
    scheduling_errors =
      Enum.flat_map(manifest.nodes, fn node ->
        []
        |> maybe_collect_error(
          not is_map(node.resources),
          "resources for node #{node.node_id} must be an object"
        )
        |> maybe_collect_error(
          not (is_list(node.constraints) or is_map(node.constraints)),
          "constraints for node #{node.node_id} must be a list or object"
        )
      end)

    add_errors(errors, scheduling_errors)
  end

  defp validate_type(errors, manifest) do
    maybe_add_error(
      errors,
      manifest.type not in ["batch", "service"],
      "type must be service or omitted for batch"
    )
  end

  defp validate_required_context_engine(errors, manifest) do
    maybe_add_error(
      errors,
      not is_boolean(manifest.required_context_engine),
      "required_context_engine must be a boolean"
    )
  end

  defp validate_requirements(errors, manifest) do
    errors
    |> maybe_add_error(
      not is_map(manifest.requirements),
      "requirements must be an object"
    )
  end

  defp validate_input_validation(errors, manifest) do
    validation = manifest.input_validation

    cond do
      is_nil(validation) ->
        errors

      is_map(validation) ->
        rules = Map.get(validation, "rules", [])

        maybe_add_error(
          errors,
          not is_list(rules),
          "input_validation.rules must be a list"
        )

      is_list(validation) ->
        errors

      true ->
        ["input_validation must be an object or list" | errors]
    end
  end

  defp validate_services(errors, manifest) do
    add_errors(errors, ServiceSpec.validate_manifest(manifest))
  end

  defp validate_deployment(errors, manifest) do
    add_errors(errors, DeploymentPolicy.validate_manifest(manifest))
  end

  defp validate_schedule(errors, manifest) do
    schedule_errors =
      case manifest.schedule do
        schedule when schedule in [%{}, nil] ->
          []

        schedule ->
          case SchedulePolicy.normalize(schedule, manifest) do
            {:ok, _normalized} -> []
            {:error, errors} -> Enum.map(errors, &"schedule: #{&1}")
          end
      end

    trigger_errors =
      manifest.triggers
      |> Enum.flat_map(fn trigger ->
        case SchedulePolicy.normalize(Map.merge(trigger, %{"kind" => "event"}), manifest) do
          {:ok, _normalized} ->
            []

          {:error, errors} ->
            Enum.map(
              errors,
              &"trigger #{trigger["name"] || trigger["event_type"] || "unknown"}: #{&1}"
            )
        end
      end)

    add_errors(errors, schedule_errors ++ trigger_errors)
  end

  defp validate_response_service(errors, %{response_service: nil}), do: errors

  defp validate_response_service(errors, %{response_service: response_service})
       when is_map(response_service) do
    unknown = Map.keys(response_service) -- ["enabled", "agent"]

    errors
    |> maybe_add_error(
      response_service["enabled"] !== true,
      "response_service.enabled must be the literal boolean true"
    )
    |> maybe_add_error(
      unknown != [],
      "response_service accepts only enabled and agent"
    )
    |> add_errors(validate_response_agent(response_service["agent"]))
  end

  defp validate_response_service(errors, _manifest) do
    ["response_service must be an object" | errors]
  end

  defp validate_response_agent(nil), do: []

  defp validate_response_agent(agent) when is_map(agent) do
    service = if is_map(agent["service"]), do: agent["service"], else: %{}
    tools = if is_map(agent["tools"]), do: agent["tools"], else: %{}
    user_tools = if is_map(tools["user"]), do: tools["user"], else: %{}
    internal_tools = if is_map(tools["internal"]), do: tools["internal"], else: %{}
    operations = if is_map(agent["operations"]), do: agent["operations"], else: %{}
    memory = if is_map(agent["memory"]), do: agent["memory"], else: %{}

    []
    |> maybe_add_error(
      not valid_response_agent_keys?(Map.keys(agent)),
      "response_service.agent must contain kind, service, tools, operations, and memory, with optional preflight"
    )
    |> maybe_add_error(
      agent["kind"] != "bounded_mcp",
      "response_service.agent.kind must be bounded_mcp"
    )
    |> maybe_add_error(
      MapSet.new(Map.keys(service)) != MapSet.new(~w(name path required_tags)) or
        not nonempty_string?(service["name"]) or not safe_mcp_path?(service["path"]) or
        not nonempty_unique_strings?(service["required_tags"]),
      "response_service.agent.service must declare an exact name, path, and required_tags"
    )
    |> maybe_add_error(
      MapSet.new(Map.keys(tools)) != MapSet.new(~w(user internal)) or user_tools == %{} or
        internal_tools == %{},
      "response_service.agent.tools must contain non-empty user and internal tool maps"
    )
    |> add_errors(validate_response_agent_tools(user_tools, true))
    |> add_errors(validate_response_agent_tools(internal_tools, false))
    |> maybe_add_error(
      MapSet.size(
        MapSet.intersection(
          MapSet.new(Map.keys(user_tools)),
          MapSet.new(Map.keys(internal_tools))
        )
      ) > 0,
      "response_service.agent user and internal tool names must be distinct"
    )
    |> add_errors(validate_response_agent_preflight(agent, user_tools))
    |> add_errors(validate_response_agent_operations(operations, user_tools, internal_tools))
    |> maybe_add_error(
      MapSet.new(Map.keys(memory)) != MapSet.new(~w(enabled mode path types max_active_records)) or
        memory["enabled"] !== true or memory["mode"] != "explicit" or
        not safe_relative_path?(memory["path"]) or
        not safe_memory_types?(memory["types"]) or
        not (is_integer(memory["max_active_records"]) and memory["max_active_records"] in 1..500),
      "response_service.agent.memory must declare bounded explicit Job memory"
    )
  end

  defp validate_response_agent(_agent), do: ["response_service.agent must be an object"]

  defp valid_response_agent_keys?(keys) do
    required = MapSet.new(~w(kind service tools operations memory))
    actual = MapSet.new(keys)
    allowed = MapSet.put(required, "preflight")

    MapSet.subset?(required, actual) and MapSet.subset?(actual, allowed)
  end

  defp validate_response_agent_preflight(agent, user_tools) do
    if Map.has_key?(agent, "preflight") do
      validate_response_agent_preflight_contract(agent["preflight"], user_tools)
    else
      []
    end
  end

  defp validate_response_agent_preflight_contract(preflight, user_tools)
       when is_map(preflight) do
    expected = MapSet.new(~w(required_for_effects tool arguments required_result))
    effects = preflight["required_for_effects"]
    tool_name = preflight["tool"]
    arguments = preflight["arguments"]
    required_result = preflight["required_result"]

    declared_tool =
      case Map.get(user_tools, tool_name) do
        value when is_map(value) -> value
        _value -> %{}
      end

    declared_arguments = Map.get(declared_tool, "arguments")

    valid =
      MapSet.new(Map.keys(preflight)) == expected and
        nonempty_unique_strings?(effects) and
        MapSet.subset?(
          MapSet.new(effects),
          MapSet.new(Enum.map(user_tools, fn {_name, tool} -> tool["effect"] end))
        ) and
        nonempty_string?(tool_name) and declared_tool["effect"] == "read" and
        is_map(arguments) and is_map(declared_arguments) and
        MapSet.new(Map.keys(arguments)) == MapSet.new(Map.keys(declared_arguments)) and
        is_map(required_result) and map_size(required_result) > 0 and
        Enum.all?(required_result, fn {key, value} ->
          nonempty_string?(key) and safe_preflight_scalar?(value)
        end)

    if valid,
      do: [],
      else: ["response_service.agent.preflight must declare a bounded live read check"]
  end

  defp validate_response_agent_preflight_contract(_preflight, _user_tools),
    do: ["response_service.agent.preflight must declare a bounded live read check"]

  defp validate_response_agent_tools(tools, user?) do
    Enum.flat_map(tools, fn {name, specification} ->
      allowed = if user?, do: ~w(arguments effect), else: ~w(arguments)

      arguments =
        if is_map(specification) and is_map(specification["arguments"]),
          do: specification["arguments"],
          else: nil

      []
      |> maybe_add_error(
        not nonempty_string?(name),
        "response_service.agent tool names must be non-empty strings"
      )
      |> maybe_add_error(
        not is_map(specification) or Map.keys(specification) -- allowed != [] or is_nil(arguments),
        "response_service.agent tool declarations have invalid fields"
      )
      |> maybe_add_error(
        user? and is_map(specification) and not safe_contract_identifier?(specification["effect"]),
        "response_service.agent user tool effects must be safe lowercase identifiers"
      )
      |> add_errors(validate_response_agent_arguments(arguments || %{}))
    end)
  end

  defp validate_response_agent_arguments(arguments) do
    Enum.flat_map(arguments, fn {name, schema} ->
      valid_schema =
        is_map(schema) and Map.keys(schema) -- ~w(type enum) == [] and
          (schema["type"] == "string" or nonempty_unique_strings?(schema["enum"])) and
          (is_nil(schema["type"]) or schema["type"] == "string") and
          (is_nil(schema["enum"]) or nonempty_unique_strings?(schema["enum"]))

      if nonempty_string?(name) and valid_schema,
        do: [],
        else: ["response_service.agent tool arguments must declare string or enum schemas"]
    end)
  end

  defp validate_response_agent_operations(operations, user_tools, internal_tools)
       when map_size(operations) > 0 do
    Enum.flat_map(operations, fn {tool_name, operation} ->
      expected = MapSet.new(~w(id_field poll_tool poll_argument poll_interval_ms timeout_seconds))

      effectful_tool =
        nonempty_string?(get_in(user_tools, [tool_name, "effect"])) and
          get_in(user_tools, [tool_name, "effect"]) != "read"

      poll_tool = if is_map(operation), do: operation["poll_tool"], else: nil
      poll_arguments = get_in(internal_tools, [poll_tool, "arguments"]) || %{}

      valid =
        effectful_tool and is_map(operation) and MapSet.new(Map.keys(operation)) == expected and
          Map.has_key?(internal_tools, poll_tool) and nonempty_string?(operation["id_field"]) and
          nonempty_string?(operation["poll_argument"]) and
          Map.has_key?(poll_arguments, operation["poll_argument"]) and
          is_integer(operation["poll_interval_ms"]) and
          operation["poll_interval_ms"] in 250..10_000 and
          is_integer(operation["timeout_seconds"]) and operation["timeout_seconds"] in 1..600

      if valid,
        do: [],
        else: [
          "response_service.agent operations must correlate declared effectful tools with internal polling tools"
        ]
    end)
  end

  defp validate_response_agent_operations(_operations, _user_tools, _internal_tools),
    do: ["response_service.agent.operations must be a non-empty object"]

  defp nonempty_unique_strings?(value) when is_list(value) and value != [] do
    Enum.all?(value, &nonempty_string?/1) and length(value) == length(Enum.uniq(value))
  end

  defp nonempty_unique_strings?(_value), do: false

  defp safe_preflight_scalar?(value),
    do: is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)

  defp safe_mcp_path?(value),
    do:
      nonempty_string?(value) and String.starts_with?(value, "/") and
        not String.contains?(value, "://")

  defp safe_relative_path?(value) do
    nonempty_string?(value) and Path.type(value) == :relative and ".." not in Path.split(value)
  end

  defp safe_memory_types?(value) do
    nonempty_unique_strings?(value) and Enum.all?(value, &safe_contract_identifier?/1)
  end

  defp safe_contract_identifier?(value) do
    nonempty_string?(value) and String.length(value) <= 80 and
      Regex.match?(~r/^[a-z][a-z0-9_]*$/, value)
  end

  defp normalize_node(raw) do
    %{
      node_id: Map.get(raw, "node_id"),
      agent_type: Map.get(raw, "agent_type"),
      type: AgentTemplates.canonical_type(Map.get(raw, "type")),
      role: Map.get(raw, "role"),
      config: Map.get(raw, "config", %{}),
      resources: Map.get(raw, "resources", %{}),
      constraints: Map.get(raw, "constraints", []),
      placement_requirements: Map.get(raw, "placement_requirements", %{}),
      tool_bindings: Map.get(raw, "tool_bindings", []),
      retry_policy: Map.get(raw, "retry_policy", %{}),
      spawn_policy: Map.get(raw, "spawn_policy", %{}),
      policies: Map.get(raw, "policies", %{}),
      services: ServiceSpec.normalize_services(Map.get(raw, "services", [])),
      requires_services:
        ServiceSpec.normalize_requires_services(Map.get(raw, "requires_services", []))
    }
  end

  defp node_to_map(node) do
    %{
      "node_id" => node.node_id,
      "agent_type" => node.agent_type,
      "type" => node.type,
      "role" => node.role,
      "config" => json_safe(node.config),
      "resources" => json_safe(node.resources),
      "constraints" => json_safe(node.constraints),
      "placement_requirements" => json_safe(Map.get(node, :placement_requirements, %{})),
      "tool_bindings" => json_safe(node.tool_bindings),
      "retry_policy" => json_safe(node.retry_policy),
      "spawn_policy" => json_safe(node.spawn_policy),
      "policies" => json_safe(Map.get(node, :policies, %{})),
      "services" => json_safe(Map.get(node, :services, [])),
      "requires_services" => json_safe(Map.get(node, :requires_services, []))
    }
  end

  defp edge_to_map(edge) do
    %{
      "edge_id" => edge.edge_id,
      "from_node" => edge.from_node,
      "to_node" => edge.to_node,
      "message_type" => edge.message_type,
      "routing_mode" => edge.routing_mode,
      "conditions" => json_safe(edge.conditions)
    }
  end

  defp normalize_edge(raw) do
    %{
      edge_id: Map.get(raw, "edge_id"),
      from_node: Map.get(raw, "from_node"),
      to_node: Map.get(raw, "to_node"),
      message_type: Map.get(raw, "message_type"),
      routing_mode: Map.get(raw, "routing_mode", "broadcast"),
      conditions: Map.get(raw, "conditions", %{})
    }
  end

  defp flow_to_map(%__MODULE__{} = manifest) do
    flow =
      case manifest.flow do
        flow when is_map(flow) -> json_safe(flow)
        _ -> %{}
      end

    flow
    |> Map.put("nodes", Enum.map(manifest.nodes, &node_to_map/1))
    |> Map.put("edges", Enum.map(manifest.edges, &edge_to_map/1))
  end

  defp normalize_entrypoints(nil, raw_nodes) do
    raw_nodes
    |> Enum.filter(&(Map.get(&1, "role") in ["root", "root_coordinator"]))
    |> Enum.map(&Map.get(&1, "node_id"))
  end

  defp normalize_entrypoints(entrypoints, _raw_nodes) when is_list(entrypoints), do: entrypoints
  defp normalize_entrypoints(entrypoint, _raw_nodes) when is_binary(entrypoint), do: [entrypoint]
  defp normalize_entrypoints(_, _), do: []

  defp normalize_initial_inputs(inputs) when is_map(inputs) do
    Enum.into(inputs, %{}, fn {node_id, payload} ->
      values = if is_list(payload), do: payload, else: [payload]
      {node_id, values}
    end)
  end

  defp normalize_initial_inputs(inputs) when is_list(inputs) do
    %{"__entrypoints__" => inputs}
  end

  defp normalize_initial_inputs(_), do: %{}

  defp normalize_reload(reload) when is_map(reload) do
    %{
      mode: Map.get(reload, "mode", "manual"),
      interval_seconds: Map.get(reload, "interval_seconds", 60)
    }
  end

  defp normalize_reload(_), do: %{mode: "manual", interval_seconds: 60}

  defp normalize_deployment(deployment) when is_map(deployment), do: json_safe(deployment)
  defp normalize_deployment(_deployment), do: %{}

  defp normalize_schedule(schedule) when is_map(schedule), do: json_safe(schedule)
  defp normalize_schedule(_schedule), do: %{}

  defp normalize_triggers(triggers) when is_list(triggers),
    do: Enum.map(triggers, &json_safe/1) |> Enum.filter(&is_map/1)

  defp normalize_triggers(trigger) when is_map(trigger), do: [json_safe(trigger)]
  defp normalize_triggers(_triggers), do: []

  defp normalize_parameterized(parameterized) when is_map(parameterized),
    do: json_safe(parameterized)

  defp normalize_parameterized(_parameterized), do: %{}

  defp normalize_response_service(nil), do: nil

  defp normalize_response_service(response_service) when is_map(response_service),
    do: json_safe(response_service)

  defp normalize_response_service(response_service), do: response_service

  defp normalize_optional_map(value) when is_map(value), do: json_safe(value)
  defp normalize_optional_map(_value), do: nil

  defp normalize_policies(nil), do: %{}
  defp normalize_policies(value), do: value

  defp normalize_optional_list(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp normalize_optional_list(_value), do: []

  defp extension_fields(raw) when is_map(raw) do
    raw
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@known_top_level_keys, key) end)
    |> Enum.into(%{}, fn {key, value} -> {key, json_safe(value)} end)
  end

  defp normalize_type(nil), do: "batch"
  defp normalize_type(value) when is_binary(value), do: String.downcase(value)
  defp normalize_type(value), do: value

  defp normalize_required_context_engine(value) when is_boolean(value), do: value
  defp normalize_required_context_engine(value), do: value

  defp json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, json_safe(value)}
    end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: inspect(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, json_safe(value))

  defp maybe_add_error(errors, true, message), do: [message | errors]
  defp maybe_add_error(errors, false, _message), do: errors

  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_value), do: false

  defp contains_completion_key?(map, target_key) when is_map(map) do
    Enum.any?(map, fn
      {^target_key, _value} ->
        true

      {_key, value} when is_map(value) ->
        contains_completion_key?(value, target_key)

      {_key, value} when is_list(value) ->
        Enum.any?(value, &contains_completion_key?(&1, target_key))

      _other ->
        false
    end)
  end

  defp contains_completion_key?(_value, _target_key), do: false

  defp valid_output_message_type?(value), do: is_binary(value) and value != ""

  defp completion_threshold?(value) when is_integer(value), do: value > 0

  defp completion_threshold?(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int > 0
      _ -> false
    end
  end

  defp completion_threshold?(_value), do: false

  defp outgoing_edge_counts(manifest) do
    Enum.reduce(manifest.edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from_node, 1, &(&1 + 1))
    end)
  end

  defp workflow_step_run_ids(manifest) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    steps = Map.get(flow, "steps", [])

    if is_list(steps) do
      steps
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn step ->
        case Map.get(step, "run") || Map.get(step, "id") do
          value when is_binary(value) -> value
          value when is_atom(value) -> Atom.to_string(value)
          value when is_integer(value) -> Integer.to_string(value)
          _value -> ""
        end
      end)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp maybe_collect_error(errors, true, message), do: [message | errors]
  defp maybe_collect_error(errors, false, _message), do: errors

  defp add_errors(errors, new_errors), do: Enum.reverse(new_errors) ++ errors
end
