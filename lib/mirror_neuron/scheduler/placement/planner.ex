defmodule MirrorNeuron.Scheduler.Placement.Planner do
  @moduledoc "Builds a placement plan from workload demand, node inventory and current usage."

  alias MirrorNeuron.Artifacts.BlobRef
  alias MirrorNeuron.Scheduler.Placement.Demand
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Scheduler.Placement.Nodes
  alias MirrorNeuron.Scheduler.Placement.Policy
  alias MirrorNeuron.Scheduler.Placement.Usage
  alias MirrorNeuron.Scheduler.Placement.Workloads

  @system_job_types ["system", "sysbatch"]

  def plan(manifest, opts) do
    with {:ok, job_type} <- Policy.normalize_job_type(manifest),
         {:ok, strategy} <- Policy.normalize_strategy(manifest),
         {:ok, demands} <- Demand.workload_demands(manifest),
         lookup_node_state <-
           Keyword.get(opts, :lookup_node_state, not Keyword.has_key?(opts, :nodes)),
         {:ok, coordination_store} <-
           Nodes.coordination_store_for_plan(opts, lookup_node_state),
         nodes <-
           opts
           |> Keyword.get_lazy(:nodes, &Nodes.default_nodes/0)
           |> Nodes.normalize_nodes(lookup_node_state, coordination_store)
           |> Nodes.apply_coordination_store_eligibility(coordination_store),
         nodes <- Nodes.exclude_nodes(nodes, Keyword.get(opts, :exclude_nodes, [])),
         nodes <- Nodes.exclusive_capacity(nodes, opts),
         nodes <- Nodes.allocated_capacity(nodes, Keyword.get(opts, :run_allocation)),
         :ok <- Nodes.ensure_coordination_store(nodes, coordination_store),
         :ok <- Nodes.ensure_nodes(nodes),
         blob_refs <- BlobRef.collect(Manifest.to_map(manifest)),
         usage <-
           opts
           |> Keyword.get_lazy(:jobs, &Usage.active_jobs/0)
           |> Usage.usage_from_jobs(Keyword.get(opts, :ignore_job_ids, [])),
         usage <-
           if(Keyword.get(opts, :exclusive_run, false),
             do:
               Map.new(nodes, &{&1["name"], Map.put(Usage.empty_usage(), "share_devices", true)}),
             else: usage
           ),
         only_agent_ids <- Keyword.get(opts, :only_agent_ids),
         service_instances <- Keyword.get(opts, :service_instances),
         {:ok, placements, placed_demands, _usage} <-
           Workloads.place_workloads(
             job_type,
             demands,
             nodes,
             usage,
             strategy,
             only_agent_ids,
             service_instances,
             blob_refs
           ),
         :ok <- ensure_single_node_workflow_plan(manifest, placements) do
      {:ok,
       %{
         "status" => "planned",
         "job_type" => job_type,
         "strategy" => strategy,
         "mode" => if(length(nodes) > 1, do: "cluster", else: "single_node"),
         "placement_count" => length(placements),
         "placements" => placements,
         "requirements" => requirements_summary(placed_demands),
         "generated_at" => MirrorNeuron.Runtime.timestamp()
       }
       |> maybe_put_system_targets(job_type, placements)}
    else
      {:error, reason} -> {:error, "placement_failed: #{reason}"}
    end
  end

  def disabled_plan(manifest) do
    {:ok, job_type} = Policy.normalize_job_type(manifest)

    %{
      "status" => "disabled",
      "job_type" => job_type,
      "strategy" => "none",
      "mode" => "local",
      "placement_count" => 0,
      "placements" => [],
      "requirements" => %{},
      "generated_at" => MirrorNeuron.Runtime.timestamp()
    }
  end

  defp ensure_single_node_workflow_plan(manifest, placements) do
    if single_node_workflow?(manifest) do
      placement_nodes =
        placements
        |> Enum.map(&Map.get(&1, "node"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      if length(placement_nodes) <= 1 do
        :ok
      else
        {:error, "single_node_manifest_spans_multiple_nodes: #{Enum.join(placement_nodes, ", ")}"}
      end
    else
      :ok
    end
  end

  defp single_node_workflow?(manifest) do
    metadata = manifest.metadata || %{}
    runtime = manifest.runtime || %{}

    get_in(metadata, ["mn_workflow_placement", "mode"]) == "single_node" or
      get_in(runtime, ["placement", "mode"]) == "single_node"
  end

  defp maybe_put_system_targets(plan, job_type, placements) when job_type in @system_job_types do
    targets =
      placements
      |> Enum.map(&Map.get(&1, "system_target", Map.get(&1, "node")))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    plan
    |> Map.put("system_targets", targets)
    |> Map.put("system_count", length(targets))
  end

  defp maybe_put_system_targets(plan, _job_type, _placements), do: plan

  defp requirements_summary(demands) do
    demands
    |> Enum.map(& &1["resources"])
    |> Enum.reduce(Usage.empty_resources(), &Usage.add_resources/2)
  end
end
