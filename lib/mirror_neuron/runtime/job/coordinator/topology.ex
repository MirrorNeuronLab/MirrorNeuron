defmodule MirrorNeuron.Runtime.JobCoordinator.Topology do
  @moduledoc "Coordinator topology, placement plans and deployment identity."

  alias MirrorNeuron.Runtime.JobCoordinator.Context
  alias MirrorNeuron.Runtime.JobCoordinator.Values
  alias MirrorNeuron.Runtime.JobTopology
  alias MirrorNeuron.Runtime.WorkflowLedger

  def build_runtime_topology(manifest, scheduler_plan),
    do: JobTopology.build(manifest, scheduler_plan)

  def compatible_runtime_topology?(state, target_manifest, scheduler_plan) do
    topology = build_runtime_topology(target_manifest, scheduler_plan)
    MapSet.new(topology.agent_ids) == MapSet.new(state.agent_ids)
  end

  def put_deployment_target(state, target_manifest, scheduler_plan, deployment_context) do
    topology = build_runtime_topology(target_manifest, scheduler_plan)

    %{
      state
      | manifest: target_manifest,
        runtime_nodes: topology.nodes,
        runtime_edges: topology.edges,
        runtime_entrypoints: topology.entrypoints,
        agent_ids: topology.agent_ids,
        source_agent_ids: topology.source_agent_ids,
        system_targets: topology.system_targets,
        agents_by_system_target: topology.agents_by_system_target,
        nodes_by_id: Map.new(topology.nodes, &{&1.node_id, &1}),
        outbound_edges_by_node: Enum.group_by(topology.edges, & &1.from_node),
        inbound_edges_by_node: Enum.group_by(topology.edges, & &1.to_node),
        downstream_by_node: build_downstream_index(topology.edges),
        workflow_state:
          WorkflowLedger.new(target_manifest, topology.nodes, %{
            "workflow_state" => state.workflow_state
          }),
        deployment_context: Values.stringify_map(deployment_context)
    }
    |> put_scheduler_plan(scheduler_plan)
    |> Context.cache_definition()
  end

  def put_runtime_scheduler_plan(state, scheduler_plan) do
    topology = build_runtime_topology(state.manifest, scheduler_plan)

    %{
      state
      | runtime_nodes: topology.nodes,
        runtime_edges: topology.edges,
        runtime_entrypoints: topology.entrypoints,
        agent_ids: topology.agent_ids,
        source_agent_ids: topology.source_agent_ids,
        system_targets: topology.system_targets,
        agents_by_system_target: topology.agents_by_system_target,
        nodes_by_id: Map.new(topology.nodes, &{&1.node_id, &1}),
        outbound_edges_by_node: Enum.group_by(topology.edges, & &1.from_node),
        inbound_edges_by_node: Enum.group_by(topology.edges, & &1.to_node),
        downstream_by_node: build_downstream_index(topology.edges),
        workflow_state:
          WorkflowLedger.new(state.manifest, topology.nodes, %{
            "workflow_state" => state.workflow_state
          })
    }
    |> put_scheduler_plan(scheduler_plan)
  end

  def runtime_topology(state), do: JobTopology.snapshot(state)

  def job_type(state), do: scheduler_plan(state)["job_type"] || "batch"

  def deployment_context_from(opts, existing_job) do
    Keyword.get(opts, :deployment_context) ||
      (is_map(existing_job) && Map.get(existing_job, "deployment")) ||
      %{}
  end

  def deployment_job_fields(state) do
    state.deployment_context || %{}
  end

  def build_downstream_index(edges), do: JobTopology.downstream_index(edges)

  def scheduler_plan(state) do
    scheduler_plan_from(state.manifest, state.opts)
  end

  def scheduler_plan_from(manifest, opts) do
    Keyword.get(opts, :scheduler_plan) || default_scheduler_plan(manifest)
  end

  defp default_scheduler_plan(manifest) do
    %{
      "status" => "unknown",
      "job_type" => manifest.type || "batch",
      "strategy" => "unknown",
      "placements" => []
    }
  end

  def put_scheduler_plan(state, scheduler_plan) do
    %{state | opts: Keyword.put(state.opts, :scheduler_plan, scheduler_plan)}
  end

  def normalize_agent_ids(agent_ids, state) do
    valid = MapSet.new(state.agent_ids)

    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&MapSet.member?(valid, &1))
    |> Enum.uniq()
  end
end
