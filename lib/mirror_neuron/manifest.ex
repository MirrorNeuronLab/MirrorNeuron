defmodule MirrorNeuron.Manifest do
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
    :input_validation,
    :services,
    :required_services,
    :deployment,
    :schedule,
    :triggers,
    :parameterized,
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
  alias MirrorNeuron.ServiceSpec
  alias MirrorNeuron.Runtime.{DeploymentPolicy, LifecyclePolicy, RouteCondition, SchedulePolicy}

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
                          "requiredContextEngine",
                          "required_context_engine",
                          "requirements",
                          "requirments",
                          "input_validation",
                          "inputValidation",
                          "services",
                          "required_services",
                          "requiredServices",
                          "deployment",
                          "schedule",
                          "triggers",
                          "parameterized",
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
      "input_validation" => json_safe(manifest.input_validation),
      "services" => json_safe(manifest.services),
      "required_services" => json_safe(manifest.required_services),
      "deployment" => json_safe(manifest.deployment),
      "schedule" => json_safe(manifest.schedule),
      "triggers" => json_safe(manifest.triggers),
      "parameterized" => json_safe(manifest.parameterized),
      "metadata" => json_safe(manifest.metadata),
      "nodes" => Enum.map(manifest.nodes, &node_to_map/1),
      "edges" => Enum.map(manifest.edges, &edge_to_map/1),
      "policies" => json_safe(manifest.policies),
      "entrypoints" => manifest.entrypoints,
      "initial_inputs" => json_safe(manifest.initial_inputs),
      "reload" => json_safe(manifest.reload)
    })
    |> maybe_put("contract", manifest.contract)
    |> maybe_put("flow", manifest.flow)
    |> maybe_put("runtime", manifest.runtime)
  end

  defp normalize_and_validate(raw) do
    raw = materialize_workflow_runtime(raw)

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
        normalize_required_context_engine(
          Map.get(raw, "requiredContextEngine", Map.get(raw, "required_context_engine", false))
        ),
      requirements: Map.get(raw, "requirements", Map.get(raw, "requirments", %{})),
      input_validation: Map.get(raw, "input_validation", Map.get(raw, "inputValidation", %{})),
      services: ServiceSpec.normalize_services(Map.get(raw, "services", [])),
      required_services:
        ServiceSpec.normalize_required_services(
          Map.get(raw, "required_services", Map.get(raw, "requiredServices", []))
        ),
      deployment: normalize_deployment(Map.get(raw, "deployment", %{})),
      schedule: normalize_schedule(Map.get(raw, "schedule", %{})),
      triggers: normalize_triggers(Map.get(raw, "triggers", [])),
      parameterized: normalize_parameterized(Map.get(raw, "parameterized", %{})),
      metadata: Map.get(raw, "metadata", %{}),
      nodes: Enum.map(Map.get(raw, "nodes", []), &normalize_node/1),
      edges: Enum.map(Map.get(raw, "edges", []), &normalize_edge/1),
      policies: Map.get(raw, "policies", %{}),
      entrypoints: normalize_entrypoints(Map.get(raw, "entrypoints"), Map.get(raw, "nodes", [])),
      initial_inputs: normalize_initial_inputs(Map.get(raw, "initial_inputs", %{})),
      reload: normalize_reload(Map.get(raw, "reload", %{})),
      extensions: extension_fields(raw)
    }

    legacy_errors = legacy_manifest_errors(raw)

    case {legacy_errors, validate(manifest)} do
      {[], :ok} -> {:ok, manifest}
      {errors, :ok} -> {:error, Enum.reverse(errors)}
      {[], {:error, errors}} -> {:error, errors}
      {legacy_errors, {:error, errors}} -> {:error, errors ++ Enum.reverse(legacy_errors)}
    end
  end

  defp materialize_workflow_runtime(%{} = raw) do
    if Map.get(raw, "nodes", []) != [] do
      raw
    else
      binding = get_in(raw, ["runtime", "bindings", "run_workflow"])
      workers = if is_map(binding), do: Map.get(binding, "workers", []), else: []

      if is_list(workers) and workers != [] do
        nodes = Enum.map(workers, &workflow_worker_to_node/1)
        entrypoints = workflow_entrypoints(binding, nodes)

        raw
        |> Map.put("nodes", nodes)
        |> Map.put("edges", Map.get(binding, "routes", Map.get(binding, "worker_edges", [])))
        |> Map.put("entrypoints", entrypoints)
        |> Map.put(
          "initial_inputs",
          Map.get(binding, "seed_inputs", Map.get(binding, "initial_inputs", %{}))
        )
      else
        raw
      end
    end
  end

  defp materialize_workflow_runtime(raw), do: raw

  defp workflow_worker_to_node(%{} = worker) do
    config = Map.get(worker, "with", Map.get(worker, "config", %{}))
    uses = Map.get(worker, "uses", "")
    kind = Map.get(worker, "kind", "")

    %{
      "node_id" => Map.get(worker, "id"),
      "agent_type" => workflow_agent_type(uses, kind),
      "type" => workflow_node_type(config, uses, kind),
      "role" => Map.get(config, "role", Map.get(worker, "role")),
      "config" => config,
      "resources" => Map.get(worker, "resources", %{}),
      "constraints" => Map.get(worker, "constraints", []),
      "tool_bindings" => Map.get(worker, "tool_bindings", []),
      "retry_policy" => Map.get(worker, "retry_policy", %{}),
      "checkpoint_policy" => Map.get(worker, "checkpoint_policy", %{}),
      "spawn_policy" => Map.get(worker, "spawn_policy", %{}),
      "policies" => Map.get(worker, "policies", %{}),
      "services" => Map.get(worker, "services", []),
      "requires_services" => Map.get(worker, "requires_services", [])
    }
  end

  defp workflow_worker_to_node(worker), do: workflow_worker_to_node(%{"id" => inspect(worker)})

  defp workflow_agent_type(uses, kind) do
    cond do
      String.contains?(to_string(uses), "control_router") -> "router"
      String.contains?(to_string(uses), "control_join") -> "aggregator"
      String.contains?(to_string(uses), "data_module") -> "module"
      kind == "stream" -> "module"
      true -> "executor"
    end
  end

  defp workflow_node_type(config, uses, kind) do
    cond do
      is_map(config) and is_binary(Map.get(config, "node_type")) -> Map.get(config, "node_type")
      String.contains?(to_string(uses), "control_router") -> "map"
      String.contains?(to_string(uses), "control_join") -> "reduce"
      kind == "stream" -> "stream"
      true -> "generic"
    end
  end

  defp workflow_entrypoints(binding, nodes) when is_map(binding) do
    case Map.get(binding, "start_workers", Map.get(binding, "entrypoints")) do
      entrypoints when is_list(entrypoints) and entrypoints != [] ->
        entrypoints

      entrypoint when is_binary(entrypoint) ->
        [entrypoint]

      _ ->
        nodes
        |> Enum.filter(&(Map.get(&1, "role") in ["root", "root_coordinator"]))
        |> Enum.map(&Map.get(&1, "node_id"))
        |> case do
          [] -> nodes |> List.first(%{}) |> Map.get("node_id") |> List.wrap()
          entrypoints -> entrypoints
        end
    end
  end

  defp workflow_entrypoints(_binding, nodes) do
    nodes |> List.first(%{}) |> Map.get("node_id") |> List.wrap()
  end

  defp legacy_manifest_errors(raw) do
    []
    |> maybe_collect_error(
      Map.has_key?(raw, "daemon"),
      "daemon is no longer supported; use type service"
    )
  end

  def validate(%__MODULE__{} = manifest) do
    errors =
      []
      |> validate_required(manifest)
      |> validate_nodes(manifest)
      |> validate_edges(manifest)
      |> validate_entrypoints(manifest)
      |> validate_type(manifest)
      |> validate_required_context_engine(manifest)
      |> validate_requirements(manifest)
      |> validate_input_validation(manifest)
      |> validate_services(manifest)
      |> validate_deployment(manifest)
      |> validate_schedule(manifest)
      |> validate_completion_contract(manifest)
      |> validate_policies(manifest)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_required(errors, manifest) do
    errors
    |> maybe_add_error(is_nil(manifest.manifest_version), "manifest_version is required")
    |> maybe_add_error(is_nil(manifest.graph_id), "graph_id is required")
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
    recovery_mode = Map.get(manifest.policies, "recovery_mode", "auto")

    errors
    |> maybe_add_error(
      recovery_mode not in supported_recovery_modes,
      "unsupported recovery_mode #{inspect(recovery_mode)}"
    )
    |> validate_scheduler_policy(manifest)
    |> validate_node_scheduling(manifest)
    |> add_errors(ResourceSpec.validate_manifest(manifest))
    |> add_errors(LifecyclePolicy.validate_manifest(manifest))
  end

  defp validate_scheduler_policy(errors, manifest) do
    job_type =
      Map.get(manifest.policies, "job_type") ||
        get_in(manifest.policies, ["scheduler", "job_type"])

    strategy =
      Map.get(manifest.policies, "scheduler_strategy") ||
        get_in(manifest.policies, ["scheduler", "strategy"])

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
      "requiredContextEngine must be a boolean"
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

  defp normalize_node(raw) do
    %{
      node_id: Map.get(raw, "node_id"),
      agent_type: Map.get(raw, "agent_type"),
      type: AgentTemplates.canonical_type(Map.get(raw, "type")),
      role: Map.get(raw, "role"),
      config: Map.get(raw, "config", %{}),
      resources: Map.get(raw, "resources", get_in(raw, ["config", "resources"]) || %{}),
      constraints: Map.get(raw, "constraints", get_in(raw, ["config", "constraints"]) || []),
      tool_bindings: Map.get(raw, "tool_bindings", []),
      retry_policy: Map.get(raw, "retry_policy", %{}),
      checkpoint_policy: Map.get(raw, "checkpoint_policy", %{}),
      spawn_policy: Map.get(raw, "spawn_policy", %{}),
      policies: Map.get(raw, "policies", %{}),
      services: ServiceSpec.normalize_services(Map.get(raw, "services", [])),
      requires_services:
        ServiceSpec.normalize_requires_services(
          Map.get(raw, "requires_services", Map.get(raw, "requiresServices", []))
        )
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
      "tool_bindings" => json_safe(node.tool_bindings),
      "retry_policy" => json_safe(node.retry_policy),
      "checkpoint_policy" => json_safe(node.checkpoint_policy),
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

  defp normalize_optional_map(value) when is_map(value), do: json_safe(value)
  defp normalize_optional_map(_value), do: nil

  defp extension_fields(raw) when is_map(raw) do
    raw
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@known_top_level_keys, key) end)
    |> Enum.into(%{}, fn {key, value} -> {key, json_safe(value)} end)
  end

  defp extension_fields(_raw), do: %{}

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
