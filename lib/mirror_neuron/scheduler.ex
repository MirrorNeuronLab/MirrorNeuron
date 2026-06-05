defmodule MirrorNeuron.Scheduler do
  @moduledoc false

  alias MirrorNeuron.Cluster.{Hardware, NodeState}
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Resource
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Scheduler.ResourceInference
  alias MirrorNeuron.ServiceRegistry
  alias MirrorNeuron.ServiceSpec

  @active_node_statuses ["healthy", "joining"]
  @active_job_statuses ["pending", "validated", "scheduled", "running", "paused"]
  @supported_job_types ["service", "batch", "system", "sysbatch"]
  @system_job_types ["system", "sysbatch"]
  @supported_strategies ["binpack", "spread"]
  @resource_keys ResourceSpec.resource_keys()

  def supported_job_types, do: @supported_job_types
  def supported_strategies, do: @supported_strategies

  def plan(%Manifest{} = manifest, opts \\ []) do
    if Keyword.get(opts, :scheduler, true) do
      do_plan(manifest, opts)
    else
      {:ok, disabled_plan(manifest)}
    end
  end

  def target_node(%{"placements" => placements}, agent_id) when is_list(placements) do
    placements
    |> Enum.find(&(Map.get(&1, "agent_id") == agent_id))
    |> case do
      %{"node" => node} -> node
      _ -> nil
    end
  end

  def target_node(_plan, _agent_id), do: nil

  def allocation(%{"placements" => placements}, agent_id) when is_list(placements) do
    placements
    |> Enum.find(&(Map.get(&1, "agent_id") == agent_id))
    |> case do
      %{"allocations" => allocations} when is_map(allocations) -> allocations
      _ -> %{}
    end
  end

  def allocation(_plan, _agent_id), do: %{}

  def affected_agent_ids(%{"placements" => placements}, node) when is_list(placements) do
    node = to_string(node)

    placements
    |> Enum.filter(&(Map.get(&1, "node") == node))
    |> Enum.map(&Map.get(&1, "agent_id"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def affected_agent_ids(_plan, _node), do: []

  def merge_plan(%{"placements" => existing_placements} = existing, %{
        "placements" => replacement_placements
      })
      when is_list(existing_placements) and is_list(replacement_placements) do
    replacement_ids =
      replacement_placements
      |> Enum.map(&Map.get(&1, "agent_id"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    placements =
      existing_placements
      |> Enum.reject(&(Map.get(&1, "agent_id") in replacement_ids))
      |> Kernel.++(replacement_placements)

    existing
    |> Map.put("placements", placements)
    |> Map.put("placement_count", length(placements))
    |> Map.put("generated_at", MirrorNeuron.Runtime.timestamp())
  end

  def merge_plan(_existing, partial), do: partial

  def job_type(%Manifest{} = manifest), do: normalize_job_type(manifest)
  def strategy(%Manifest{} = manifest), do: normalize_strategy(manifest)

  defp do_plan(manifest, opts) do
    with {:ok, job_type} <- normalize_job_type(manifest),
         {:ok, strategy} <- normalize_strategy(manifest),
         {:ok, demands} <- workload_demands(manifest),
         lookup_node_state <-
           Keyword.get(opts, :lookup_node_state, not Keyword.has_key?(opts, :nodes)),
         nodes <-
           opts
           |> Keyword.get_lazy(:nodes, &default_nodes/0)
           |> normalize_nodes(lookup_node_state),
         nodes <- exclude_nodes(nodes, Keyword.get(opts, :exclude_nodes, [])),
         :ok <- ensure_nodes(nodes),
         usage <-
           opts
           |> Keyword.get_lazy(:jobs, &active_jobs/0)
           |> usage_from_jobs(Keyword.get(opts, :ignore_job_ids, [])),
         only_agent_ids <- Keyword.get(opts, :only_agent_ids),
         service_instances <- Keyword.get(opts, :service_instances),
         {:ok, placements, placed_demands, _usage} <-
           place_workloads(
             job_type,
             demands,
             nodes,
             usage,
             strategy,
             only_agent_ids,
             service_instances
           ) do
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

  defp disabled_plan(manifest) do
    {:ok, job_type} = normalize_job_type(manifest)

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

  defp normalize_job_type(manifest) do
    type =
      manifest.policies
      |> policy_value("job_type", get_in(manifest.policies || %{}, ["scheduler", "job_type"]))
      |> case do
        nil -> manifest.type || "batch"
        value -> value
      end
      |> to_string()
      |> String.downcase()

    if type in @supported_job_types do
      {:ok, type}
    else
      {:error, "unsupported job_type #{inspect(type)}"}
    end
  end

  defp normalize_strategy(manifest) do
    strategy =
      manifest.policies
      |> policy_value(
        "scheduler_strategy",
        get_in(manifest.policies || %{}, ["scheduler", "strategy"])
      )
      |> case do
        nil -> "binpack"
        value -> value
      end
      |> to_string()
      |> String.downcase()

    if strategy in @supported_strategies do
      {:ok, strategy}
    else
      {:error, "unsupported scheduler strategy #{inspect(strategy)}"}
    end
  end

  defp policy_value(nil, _key, default), do: default

  defp policy_value(policies, key, default) when is_map(policies),
    do: Map.get(policies, key, default)

  defp policy_value(_policies, _key, default), do: default

  defp workload_demands(manifest) do
    global_constraints = scheduler_constraints(manifest.policies)

    demands =
      Enum.map(manifest.nodes, fn node ->
        resource_request = resource_request_for_node(node)
        constraints = global_constraints ++ constraints_for_node(node)
        requires_services = ServiceSpec.node_requires_services(node)

        inferred =
          ResourceInference.infer(
            manifest,
            node,
            resource_request,
            constraints,
            requires_services
          )

        resource_request = inferred["resource_request"]

        %{
          "agent_id" => node.node_id,
          "agent_type" => node.agent_type,
          "resources" => resource_request["resources"],
          "resource_request" => resource_request,
          "constraints" => inferred["constraints"],
          "profile" => execution_profile(node),
          "requires_services" => inferred["requires_services"],
          "placement_requirements" => inferred["placement_requirements"]
        }
      end)

    {:ok, demands}
  end

  defp scheduler_constraints(policies) when is_map(policies) do
    []
    |> Kernel.++(normalize_constraints(Map.get(policies, "constraints", [])))
    |> Kernel.++(normalize_constraints(get_in(policies, ["scheduler", "constraints"]) || []))
  end

  defp scheduler_constraints(_policies), do: []

  defp resource_request_for_node(node) do
    explicit =
      Map.get(node, :resources) ||
        Map.get(node, "resources") ||
        get_in(node, [:config, "resources"]) ||
        get_in(node, ["config", "resources"]) ||
        %{}

    explicit
    |> ResourceSpec.normalize_request()
    |> add_profile_gpu_need(node)
    |> ResourceSpec.with_runtime_driver(ResourceSpec.infer_runtime_driver(node_config(node)))
  end

  defp constraints_for_node(node) do
    constraints =
      Map.get(node, :constraints) ||
        Map.get(node, "constraints") ||
        get_in(node, [:config, "constraints"]) ||
        get_in(node, ["config", "constraints"]) ||
        []

    normalize_constraints(constraints)
  end

  defp execution_profile(node) do
    MirrorNeuron.Execution.Profile.profile_name(
      Map.get(node, :config) || Map.get(node, "config") || %{}
    )
  end

  defp node_config(node), do: Map.get(node, :config) || Map.get(node, "config") || %{}

  defp add_profile_gpu_need(resource_request, node) do
    case execution_profile(node) do
      nil ->
        resource_request

      profile_name ->
        case MirrorNeuron.Execution.Profile.fetch(profile_name) do
          {:ok, %{"gpu" => gpu?}}
          when gpu? in [true, "true", "TRUE", "True", "1", 1, "yes", "on"] ->
            ResourceSpec.add_gpu_need(resource_request, 1)

          _ ->
            resource_request
        end
    end
  end

  defp normalize_resources(resources), do: ResourceSpec.scalar_resources(resources)
  defp empty_resources, do: ResourceSpec.empty_resources()

  defp normalize_constraints(constraints) when is_list(constraints) do
    Enum.map(constraints, &normalize_constraint/1)
  end

  defp normalize_constraints(constraint) when is_map(constraint),
    do: [normalize_constraint(constraint)]

  defp normalize_constraints(_constraints), do: []

  defp normalize_constraint(constraint) when is_map(constraint) do
    %{
      "attribute" =>
        Map.get(constraint, "attribute") ||
          Map.get(constraint, :attribute) ||
          Map.get(constraint, "target") ||
          Map.get(constraint, :target) ||
          Map.get(constraint, "l_target") ||
          Map.get(constraint, :l_target),
      "operator" =>
        Map.get(constraint, "operator") ||
          Map.get(constraint, :operator) ||
          Map.get(constraint, "operand") ||
          Map.get(constraint, :operand) ||
          "==",
      "value" =>
        Map.get(constraint, "value") ||
          Map.get(constraint, :value) ||
          Map.get(constraint, "r_target") ||
          Map.get(constraint, :r_target)
    }
  end

  defp normalize_constraint(value) when is_binary(value) do
    %{"attribute" => "capabilities", "operator" => "contains", "value" => value}
  end

  defp normalize_constraint(value) do
    %{"attribute" => "capabilities", "operator" => "contains", "value" => to_string(value)}
  end

  defp default_nodes do
    case MirrorNeuron.inspect_nodes() do
      nodes when is_list(nodes) and nodes != [] ->
        nodes

      _ ->
        [%{"name" => to_string(Node.self()), "hardware" => Hardware.info()}]
    end
  rescue
    _ -> [%{"name" => to_string(Node.self()), "hardware" => Hardware.info()}]
  end

  defp normalize_nodes(nodes, lookup_node_state) do
    nodes
    |> List.wrap()
    |> Enum.map(&normalize_node(&1, lookup_node_state))
    |> Enum.reject(&is_nil/1)
  end

  defp exclude_nodes(nodes, excluded) do
    excluded =
      excluded
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.reject(nodes, &(Map.get(&1, "name") in excluded))
  end

  defp normalize_node(node, lookup_node_state) when is_map(node) do
    name = map_get(node, "name") || map_get(node, "node") || to_string(Node.self())
    stored = if lookup_node_state, do: stored_node_state(name), else: %{}
    hardware = map_get(node, "hardware") || map_get(stored, "hardware") || local_hardware(name)
    status = map_get(node, "status") || map_get(stored, "status") || "healthy"
    hardware = stringify_map(hardware)
    stored = stringify_map(stored)

    node_with_state =
      stored
      |> Map.merge(stringify_map(node))
      |> Map.put("hardware", hardware)

    host_paths =
      ResourceSpec.normalize_node_host_paths(
        node_with_state,
        hardware
      )

    runtime_drivers =
      ResourceSpec.normalize_node_runtime_drivers(
        node_with_state,
        hardware
      )

    scheduling_eligible =
      map_get(node, "scheduling_eligible")
      |> case do
        nil -> map_get(stored, "scheduling_eligible")
        value -> value
      end
      |> eligible_value()

    capabilities =
      []
      |> Kernel.++(list_value(map_get(node, "capabilities")))
      |> Kernel.++(list_value(map_get(stored, "capabilities")))
      |> Kernel.++(list_value(map_get(hardware, "capabilities")))
      |> Kernel.++(
        hardware
        |> map_get("devices")
        |> List.wrap()
        |> Enum.flat_map(&list_value(map_get(&1, "capabilities")))
      )
      |> Kernel.++(
        hardware
        |> map_get("gpu")
        |> List.wrap()
        |> Enum.flat_map(fn
          gpu when is_map(gpu) -> list_value(map_get(gpu, "capabilities"))
          _gpu -> []
        end)
      )
      |> Enum.map(&(to_string(&1) |> String.downcase() |> String.replace("_", "-")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    %{
      "name" => name,
      "status" => status,
      "scheduling_eligible" => scheduling_eligible,
      "drain" => map_get(node, "drain") || map_get(stored, "drain"),
      "hardware" => hardware,
      "profiles" => list_value(map_get(node, "profiles") || map_get(stored, "profiles")),
      "capabilities" => capabilities,
      "gpu" => truthy?(map_get(node, "gpu") || map_get(stored, "gpu")) || gpu_count(hardware) > 0,
      "node_role" => map_get(node, "node_role") || map_get(stored, "node_role") || "runtime",
      "capacity" => node_capacity(hardware),
      "devices" => ResourceSpec.normalize_node_devices(node_with_state),
      "host_paths" => host_paths,
      "runtime_drivers" => runtime_drivers
    }
  end

  defp normalize_node(_node, _lookup_node_state), do: nil

  defp stored_node_state(name) do
    case NodeState.fetch(name) do
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp local_hardware(name) do
    if name == to_string(Node.self()), do: Hardware.info(), else: %{}
  rescue
    _ -> %{}
  end

  defp ensure_nodes([]), do: {:error, "no runtime nodes are available"}

  defp ensure_nodes(nodes) do
    if Enum.any?(nodes, &schedulable_node?/1) do
      :ok
    else
      {:error, "no schedulable runtime nodes are available"}
    end
  end

  defp active_jobs do
    case RedisStore.list_jobs() do
      {:ok, jobs} -> jobs
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  end

  defp usage_from_jobs(jobs, ignored_job_ids) do
    ignored_job_ids =
      ignored_job_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    jobs
    |> List.wrap()
    |> Enum.filter(fn job ->
      Map.get(job, "status") in @active_job_statuses and
        Map.get(job, "job_id") not in ignored_job_ids
    end)
    |> Enum.flat_map(&(get_in(&1, ["scheduler", "placements"]) || []))
    |> Enum.reduce(%{}, fn placement, acc ->
      node = Map.get(placement, "node")
      resources = normalize_resources(Map.get(placement, "resources", %{}))
      allocation = Map.get(placement, "allocations", %{})

      if is_binary(node) do
        Map.update(
          acc,
          node,
          add_usage(empty_usage(), resources, allocation),
          &add_usage(&1, resources, allocation)
        )
      else
        acc
      end
    end)
  end

  defp empty_usage do
    %{
      "resources" => empty_resources(),
      "devices" => MapSet.new(),
      "ports" => MapSet.new()
    }
  end

  defp normalize_usage(%{"resources" => resources} = usage) do
    %{
      "resources" => normalize_resources(resources),
      "devices" => Map.get(usage, "devices", MapSet.new()) |> to_mapset(),
      "ports" => Map.get(usage, "ports", MapSet.new()) |> to_mapset()
    }
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      "resources" => normalize_resources(usage),
      "devices" => MapSet.new(),
      "ports" => MapSet.new()
    }
  end

  defp normalize_usage(_usage), do: empty_usage()

  defp usage_for_node(usage, node_name),
    do: Map.get(usage, node_name, empty_usage()) |> normalize_usage()

  defp add_usage(used, resources, allocation) do
    used = normalize_usage(used)

    %{
      "resources" => add_resources(used["resources"], resources),
      "devices" => MapSet.union(used["devices"], allocated_device_ids(allocation)),
      "ports" => MapSet.union(used["ports"], allocated_port_keys(allocation))
    }
  end

  defp merge_usage(left, right) do
    left = normalize_usage(left)
    right = normalize_usage(right)

    %{
      "resources" => add_resources(left["resources"], right["resources"]),
      "devices" => MapSet.union(left["devices"], right["devices"]),
      "ports" => MapSet.union(left["ports"], right["ports"])
    }
  end

  defp to_mapset(%MapSet{} = set), do: set
  defp to_mapset(values) when is_list(values), do: MapSet.new(values)
  defp to_mapset(_values), do: MapSet.new()

  defp allocated_device_ids(%{"devices" => devices}) when is_list(devices) do
    devices
    |> Enum.map(&(Map.get(&1, "id") || Map.get(&1, :id)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp allocated_device_ids(_allocation), do: MapSet.new()

  defp allocated_port_keys(%{"ports" => ports}) when is_list(ports) do
    ports
    |> Enum.map(&port_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp allocated_port_keys(_allocation), do: MapSet.new()

  defp filter_demands(demands, nil), do: demands

  defp filter_demands(demands, agent_ids) do
    agent_ids =
      agent_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(demands, &(Map.get(&1, "agent_id") in agent_ids))
  end

  defp place_workloads(
         job_type,
         demands,
         nodes,
         usage,
         strategy,
         only_agent_ids,
         service_instances
       )
       when job_type in @system_job_types do
    place_system_demands(demands, nodes, usage, strategy, only_agent_ids, service_instances)
  end

  defp place_workloads(
         _job_type,
         demands,
         nodes,
         usage,
         strategy,
         only_agent_ids,
         service_instances
       ) do
    demands = filter_demands(demands, only_agent_ids)

    with {:ok, placements, usage} <-
           place_demands(demands, nodes, usage, strategy, service_instances) do
      {:ok, placements, demands, usage}
    end
  end

  defp place_system_demands(demands, nodes, usage, strategy, only_agent_ids, service_instances) do
    only_agent_ids = normalize_agent_id_filter(only_agent_ids)

    eligible =
      nodes
      |> Enum.filter(&schedulable_node?/1)
      |> Enum.reduce([], fn node, acc ->
        case system_node_plan(
               node,
               demands,
               usage_for_node(usage, node["name"]),
               service_instances
             ) do
          {:ok, group_plan} ->
            score =
              score_node(
                node,
                usage_for_node(usage, node["name"]),
                group_plan["resources"],
                strategy
              )

            [{node, group_plan, score} | acc]

          :error ->
            acc
        end
      end)
      |> Enum.reverse()

    case eligible do
      [] ->
        {:error, no_system_candidate_reason(demands, nodes, usage, service_instances)}

      eligible ->
        {placements, placed_demands, usage} =
          Enum.reduce(eligible, {[], [], usage}, fn {node, group_plan, score},
                                                    {placement_acc, demand_acc, usage_acc} ->
            target_node = node["name"]

            target_placements =
              demands
              |> Enum.map(
                &system_placement(
                  &1,
                  target_node,
                  score,
                  get_in(group_plan, ["allocations", &1["agent_id"]]) || empty_allocation()
                )
              )
              |> Enum.filter(&placement_selected?(&1, only_agent_ids))

            target_demands =
              target_placements
              |> Enum.map(&placement_to_demand/1)

            next_usage =
              if target_placements == [] do
                usage_acc
              else
                Map.update(
                  usage_acc,
                  target_node,
                  group_plan["usage"],
                  &merge_usage(&1, group_plan["usage"])
                )
              end

            {placement_acc ++ target_placements, demand_acc ++ target_demands, next_usage}
          end)

        {:ok, placements, placed_demands, usage}
    end
  end

  defp system_node_plan(node, demands, used, service_instances) do
    if schedulable_node?(node) and
         Enum.all?(demands, &system_demand_eligible?(&1, node, service_instances)) do
      demands
      |> Enum.reduce_while(
        {:ok, empty_resources(), %{}, normalize_usage(used)},
        fn demand, {:ok, resources_acc, allocations, used_acc} ->
          case fit_allocation(node, used_acc, demand) do
            {:ok, allocation} ->
              {:cont,
               {:ok, add_resources(resources_acc, demand["resources"]),
                Map.put(allocations, demand["agent_id"], allocation),
                add_usage(used_acc, demand["resources"], allocation)}}

            {:error, _reason} ->
              {:halt, :error}
          end
        end
      )
      |> case do
        {:ok, group_resources, allocations, next_usage} ->
          {:ok,
           %{"resources" => group_resources, "allocations" => allocations, "usage" => next_usage}}

        :error ->
          :error
      end
    else
      :error
    end
  end

  defp system_demand_eligible?(demand, node, service_instances) do
    profile_match?(demand["profile"], node) and constraints_match?(demand["constraints"], node) and
      service_requirements_match?(demand, node, service_instances)
  end

  defp system_placement(demand, target_node, score, allocation) do
    %{
      "agent_id" => system_agent_id(demand["agent_id"], target_node),
      "source_agent_id" => demand["agent_id"],
      "agent_type" => demand["agent_type"],
      "node" => target_node,
      "system_target" => target_node,
      "resources" => demand["resources"],
      "allocations" => allocation,
      "constraints" => demand["constraints"],
      "placement_requirements" => demand["placement_requirements"],
      "score" => Float.round(score, 4)
    }
  end

  defp placement_to_demand(placement) do
    %{
      "agent_id" => placement["agent_id"],
      "agent_type" => placement["agent_type"],
      "resources" => placement["resources"],
      "resource_request" =>
        placement["resource_request"] || %{"resources" => placement["resources"]},
      "constraints" => placement["constraints"]
    }
  end

  defp placement_selected?(_placement, nil), do: true

  defp placement_selected?(placement, only_agent_ids) do
    placement["agent_id"] in only_agent_ids or placement["source_agent_id"] in only_agent_ids
  end

  defp normalize_agent_id_filter(nil), do: nil

  defp normalize_agent_id_filter(agent_ids) do
    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp system_agent_id(agent_id, target_node), do: "#{agent_id}@#{target_node}"

  defp no_system_candidate_reason(demands, nodes, usage, service_instances) do
    demand_ids = demands |> Enum.map(& &1["agent_id"]) |> Enum.join(", ")

    reasons =
      nodes
      |> Enum.map(fn node ->
        used = usage_for_node(usage, node["name"])

        cond do
          not schedulable_node?(node) ->
            "#{node["name"]}: #{unschedulable_reason(node)}"

          not Enum.all?(demands, &system_demand_eligible?(&1, node, service_instances)) ->
            "#{node["name"]}: constraints, profiles, services, or capabilities not matched"

          not match?({:ok, _}, system_node_plan(node, demands, used, service_instances)) ->
            "#{node["name"]}: insufficient resources for system group"

          true ->
            "#{node["name"]}: unavailable"
        end
      end)

    "system job agents #{demand_ids} have no eligible nodes (#{Enum.join(reasons, "; ")})"
  end

  defp place_demands(demands, nodes, usage, strategy, service_instances) do
    Enum.reduce_while(demands, {:ok, [], usage}, fn demand, {:ok, placements, usage_acc} ->
      case choose_node(demand, nodes, usage_acc, strategy, service_instances) do
        {:ok, node, score, allocation} ->
          next_usage =
            Map.update(
              usage_acc,
              node["name"],
              add_usage(empty_usage(), demand["resources"], allocation),
              &add_usage(&1, demand["resources"], allocation)
            )

          placement = %{
            "agent_id" => demand["agent_id"],
            "agent_type" => demand["agent_type"],
            "node" => node["name"],
            "resources" => demand["resources"],
            "allocations" => allocation,
            "constraints" => demand["constraints"],
            "placement_requirements" => demand["placement_requirements"],
            "score" => Float.round(score, 4)
          }

          {:cont, {:ok, [placement | placements], next_usage}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, placements, usage_acc} -> {:ok, Enum.reverse(placements), usage_acc}
      error -> error
    end
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

  defp choose_node(demand, nodes, usage, strategy, service_instances) do
    candidates =
      nodes
      |> Enum.filter(&schedulable_node?/1)
      |> Enum.filter(&profile_match?(demand["profile"], &1))
      |> Enum.filter(&constraints_match?(demand["constraints"], &1))
      |> Enum.filter(&service_requirements_match?(demand, &1, service_instances))
      |> Enum.flat_map(fn node ->
        used = usage_for_node(usage, node["name"])

        case fit_allocation(node, used, demand) do
          {:ok, allocation} -> [{node, allocation}]
          {:error, _reason} -> []
        end
      end)

    case candidates do
      [] ->
        {:error, no_candidate_reason(demand, nodes, usage, service_instances)}

      candidates ->
        {node, allocation, score} =
          candidates
          |> Enum.map(fn {node, allocation} ->
            {node, allocation,
             score_node(
               node,
               usage_for_node(usage, node["name"]),
               demand["resources"],
               strategy
             )}
          end)
          |> Enum.max_by(fn {_node, _allocation, score} -> score end)

        {:ok, node, score, allocation}
    end
  end

  defp no_candidate_reason(demand, nodes, usage, service_instances) do
    reasons =
      nodes
      |> Enum.map(fn node ->
        cond do
          not schedulable_node?(node) ->
            "#{node["name"]}: #{unschedulable_reason(node)}"

          not profile_match?(demand["profile"], node) ->
            "#{node["name"]}: execution profile not available"

          not constraints_match?(demand["constraints"], node) ->
            "#{node["name"]}: constraints not matched"

          not service_requirements_match?(demand, node, service_instances) ->
            "#{node["name"]}: required services not available"

          not capacity_available?(
            node,
            usage_for_node(usage, node["name"]),
            demand["resources"]
          ) ->
            "#{node["name"]}: insufficient resources"

          not match?(
            {:ok, _allocation},
            fit_allocation(node, usage_for_node(usage, node["name"]), demand)
          ) ->
            "#{node["name"]}: devices, ports, volumes, or runtime driver not available"

          true ->
            "#{node["name"]}: unavailable"
        end
      end)

    requirement_text = demand_requirement_text(demand)

    "agent #{demand["agent_id"]}#{requirement_text} has no eligible node (#{Enum.join(reasons, "; ")})"
  end

  defp demand_requirement_text(%{"placement_requirements" => %{"models" => models}})
       when is_list(models) and models != [] do
    details =
      models
      |> Enum.map(fn model ->
        service = get_in(model, ["service", "name"])
        capabilities = Map.get(model, "required_capabilities", [])
        min_vram = Map.get(model, "min_vram_mb")

        [
          Map.get(model, "id") || Map.get(model, "model"),
          if(service, do: "service #{service}", else: nil),
          if(is_number(min_vram), do: "gpu >= #{Float.round(min_vram / 1024, 1)}GB", else: nil),
          if(capabilities != [],
            do: "capability any of #{Enum.join(capabilities, ",")}",
            else: nil
          )
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
      end)
      |> Enum.reject(&(&1 == ""))

    if details == [] do
      ""
    else
      " requiring #{Enum.join(details, "; ")}"
    end
  end

  defp demand_requirement_text(_demand), do: ""

  defp capacity_available?(node, used, ask) do
    capacity = node["capacity"] || empty_resources()
    used_resources = normalize_usage(used)["resources"]

    Enum.all?(@resource_keys, fn key ->
      Map.get(used_resources, key, 0) + Map.get(ask, key, 0) <= Map.get(capacity, key, 0)
    end)
  end

  defp fit_allocation(node, used, demand) do
    used = normalize_usage(used)

    resource_request =
      Map.get(demand, "resource_request") || %{"resources" => demand["resources"]}

    with :ok <- scalar_capacity_available(node, used, demand["resources"]),
         {:ok, runtime_driver} <- allocate_runtime_driver(node, resource_request),
         {:ok, ports} <- allocate_ports(resource_request, used),
         {:ok, volumes} <- allocate_volumes(node, resource_request),
         {:ok, devices} <- allocate_devices(node, used, resource_request) do
      {:ok,
       %{
         "devices" => devices,
         "ports" => ports,
         "volumes" => volumes,
         "runtime_driver" => runtime_driver
       }}
    end
  end

  defp scalar_capacity_available(node, used, ask) do
    if capacity_available?(node, used, ask || empty_resources()) do
      :ok
    else
      {:error, :insufficient_resources}
    end
  end

  defp allocate_runtime_driver(node, %{"runtime_driver" => driver})
       when is_binary(driver) and driver != "" do
    if driver in Map.get(node, "runtime_drivers", []) do
      {:ok, driver}
    else
      {:error, :runtime_driver_unavailable}
    end
  end

  defp allocate_runtime_driver(_node, _resource_request), do: {:ok, nil}

  defp allocate_ports(%{"ports" => ports}, used) when is_list(ports) do
    requested_keys = Enum.map(ports, &port_key/1)

    cond do
      Enum.any?(requested_keys, &is_nil/1) ->
        {:error, :invalid_port_request}

      length(requested_keys) != length(Enum.uniq(requested_keys)) ->
        {:error, :port_conflict}

      Enum.any?(requested_keys, &MapSet.member?(used["ports"], &1)) ->
        {:error, :port_conflict}

      true ->
        {:ok, ports}
    end
  end

  defp allocate_ports(_resource_request, _used), do: {:ok, []}

  defp allocate_volumes(node, %{"volumes" => volumes}) when is_list(volumes) do
    host_paths = Map.get(node, "host_paths", [])

    if Enum.all?(volumes, &volume_available?(&1, host_paths, node["name"])) do
      {:ok, volumes}
    else
      {:error, :volume_unavailable}
    end
  end

  defp allocate_volumes(_node, _resource_request), do: {:ok, []}

  defp allocate_devices(node, used, resource_request) do
    requests = ResourceSpec.scheduling_devices(resource_request)
    devices = Map.get(node, "devices", [])
    used_device_ids = used["devices"]

    Enum.reduce_while(requests, {:ok, [], used_device_ids}, fn request,
                                                               {:ok, selected, used_ids} ->
      available =
        devices
        |> Enum.reject(&(Map.get(&1, "id") in used_ids))
        |> Enum.filter(&device_matches?(&1, request))
        |> Enum.sort_by(&device_sort_key(&1, request))

      count = trunc(Map.get(request, "count", 1) || 1)
      picked = Enum.take(available, count)

      if length(picked) == count do
        next_used = MapSet.union(used_ids, allocated_device_ids(%{"devices" => picked}))
        {:cont, {:ok, selected ++ picked, next_used}}
      else
        {:halt, {:error, :device_unavailable}}
      end
    end)
    |> case do
      {:ok, devices, _used_ids} -> {:ok, devices}
      {:error, reason} -> {:error, reason}
    end
  end

  defp device_matches?(device, request) do
    kind = String.downcase(to_string(Map.get(request, "kind") || ""))
    request_type = String.downcase(to_string(Map.get(request, "type") || ""))
    request_vendor = Map.get(request, "vendor")
    request_driver = Map.get(request, "driver")
    request_type_vendor = vendor_from_type(request_type)
    request_capabilities = Map.get(request, "capabilities", [])
    request_ids = Map.get(request, "ids", [])
    min_memory = Map.get(request, "min_memory_mb")

    device_kind = String.downcase(to_string(Map.get(device, "kind") || ""))
    device_type = String.downcase(to_string(Map.get(device, "type") || ""))
    device_vendor = Map.get(device, "vendor")
    device_driver = Map.get(device, "driver")
    device_capabilities = Map.get(device, "capabilities", [])
    device_id = to_string(Map.get(device, "id"))
    device_memory = Map.get(device, "memory_free_mb") || Map.get(device, "memory_total_mb")

    Enum.all?([
      kind == "" or kind == device_kind or kind in device_capabilities,
      request_type in ["", "device"] or
        request_type == device_type or
        (String.contains?(request_type, "gpu") and
           (device_kind == "gpu" or "gpu" in device_capabilities)),
      request_type_vendor in [nil, ""] or is_nil(device_vendor) or
        request_type_vendor == device_vendor,
      request_vendor in [nil, ""] or request_vendor == device_vendor,
      request_driver in [nil, ""] or request_driver == device_driver,
      request_ids == [] or device_id in Enum.map(request_ids, &to_string/1),
      Enum.all?(request_capabilities, &(String.downcase(to_string(&1)) in device_capabilities)),
      is_nil(min_memory) or (is_number(device_memory) and device_memory >= min_memory)
    ])
  end

  defp device_sort_key(device, request) do
    min_memory = Map.get(request, "min_memory_mb")
    memory = Map.get(device, "memory_free_mb") || Map.get(device, "memory_total_mb") || 0

    if is_number(min_memory) do
      {memory - min_memory, memory}
    else
      {memory, to_string(Map.get(device, "id"))}
    end
  end

  defp vendor_from_type(type) do
    case String.split(to_string(type), "/", parts: 2) do
      [vendor, "gpu"] when vendor not in ["", "gpu", "device"] -> vendor
      _ -> nil
    end
  end

  defp port_key(%{"port" => port} = request) do
    protocol = Map.get(request, "protocol", "tcp") |> to_string() |> String.downcase()
    "#{protocol}:#{trunc(port)}"
  rescue
    _ -> nil
  end

  defp port_key(_request), do: nil

  defp volume_available?(%{"source" => source}, host_paths, node_name) do
    source = Path.expand(to_string(source))

    Enum.any?(host_paths, fn host_path ->
      source == host_path or String.starts_with?(source, host_path <> "/")
    end) or (node_name == to_string(Node.self()) and File.exists?(source))
  end

  defp volume_available?(_volume, _host_paths, _node_name), do: false

  defp empty_allocation do
    %{"devices" => [], "ports" => [], "volumes" => [], "runtime_driver" => nil}
  end

  defp service_requirements_match?(
         %{"requires_services" => requirements},
         _node,
         _service_instances
       )
       when requirements in [nil, []],
       do: true

  defp service_requirements_match?(
         %{"requires_services" => requirements},
         node,
         service_instances
       ) do
    ServiceRegistry.requirements_satisfied_on_node?(requirements, node["name"],
      service_instances: service_instances
    )
  end

  defp service_requirements_match?(_demand, _node, _service_instances), do: true

  defp schedulable_node?(node) do
    Map.get(node, "status") in @active_node_statuses and
      Map.get(node, "scheduling_eligible", true) != false
  end

  defp unschedulable_reason(node) do
    cond do
      Map.get(node, "status") not in @active_node_statuses ->
        "status #{inspect(node["status"])}"

      Map.get(node, "scheduling_eligible", true) == false ->
        "scheduling is disabled"

      true ->
        "unavailable"
    end
  end

  defp score_node(node, used, ask, "spread") do
    capacity = node["capacity"] || empty_resources()

    @resource_keys
    |> Enum.map(&resource_ratio(capacity, used, ask, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 1.0
      ratios -> 1.0 - Enum.sum(ratios) / length(ratios)
    end
  end

  defp score_node(node, used, ask, _binpack) do
    capacity = node["capacity"] || empty_resources()

    @resource_keys
    |> Enum.map(&resource_ratio(capacity, used, ask, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0.0
      ratios -> Enum.sum(ratios) / length(ratios)
    end
  end

  defp resource_ratio(capacity, used, ask, key) do
    total = Map.get(capacity, key, 0)
    used_resources = normalize_usage(used)["resources"]

    if total > 0 do
      (Map.get(used_resources, key, 0) + Map.get(ask, key, 0)) / total
    else
      nil
    end
  end

  defp constraints_match?(constraints, node) do
    Enum.all?(constraints, &constraint_match?(&1, node))
  end

  defp constraint_match?(
         %{"attribute" => attribute, "operator" => operator, "value" => value},
         node
       ) do
    current = node_attribute(node, attribute)

    case normalize_operator(operator) do
      "==" -> to_string(current) == to_string(value)
      "!=" -> to_string(current) != to_string(value)
      "contains" -> to_string(value) in list_value(current)
      "contains_all" -> Enum.all?(list_value(value), &(&1 in list_value(current)))
      "contains_any" -> Enum.any?(list_value(value), &(&1 in list_value(current)))
      "in" -> to_string(current) in list_value(value)
      "exists" -> not is_nil(current)
      "not_exists" -> is_nil(current)
      _ -> false
    end
  end

  defp constraint_match?(_constraint, _node), do: true

  defp profile_match?(nil, _node), do: true

  defp profile_match?(profile, node) do
    MirrorNeuron.Execution.Profile.eligible_node?(profile, %{
      "node" => node["name"],
      "status" => node["status"],
      "profiles" => node["profiles"],
      "capabilities" => node["capabilities"],
      "gpu" => node["gpu"]
    })
  end

  defp normalize_operator(operator) do
    case operator |> to_string() |> String.downcase() do
      "=" -> "=="
      "==" -> "=="
      "is" -> "=="
      "!=" -> "!="
      "not" -> "!="
      "set_contains" -> "contains"
      "contains" -> "contains"
      "set_contains_all" -> "contains_all"
      "contains_all" -> "contains_all"
      "set_contains_any" -> "contains_any"
      "contains_any" -> "contains_any"
      "in" -> "in"
      "is_set" -> "exists"
      "exists" -> "exists"
      "is_not_set" -> "not_exists"
      "not_exists" -> "not_exists"
      other -> other
    end
  end

  defp node_attribute(node, attribute) do
    case attribute |> to_string() |> String.trim("${}") do
      value when value in ["node", "node.name", "node.unique.name"] ->
        node["name"]

      value when value in ["status", "node.status"] ->
        node["status"]

      value when value in ["node_role", "role", "node.role"] ->
        node["node_role"]

      value when value in ["gpu", "node.gpu"] ->
        node["gpu"]

      value when value in ["profiles", "profile", "execution_profile"] ->
        node["profiles"]

      value when value in ["capabilities", "capability"] ->
        node["capabilities"]

      value when value in ["os", "platform.os"] ->
        get_in(node, ["hardware", "platform", "os"]) ||
          get_in(node, ["hardware", "platform", "family"])

      value when value in ["arch", "architecture", "cpu.arch"] ->
        get_in(node, ["hardware", "cpu", "architecture"])

      path ->
        get_path(node, String.split(path, "."))
    end
  end

  defp node_capacity(hardware) do
    hardware = stringify_map(hardware)
    cpu = number_value(get_in(hardware, ["cpu", "logical_processors"])) || 0
    memory = memory_capacity_mb(get_in(hardware, ["memory"]) || %{})
    disk = disk_capacity_mb(get_in(hardware, ["disk"]) || %{})
    gpu = gpu_count(get_in(hardware, ["gpu"]))

    %{
      "cpu_cores" => Float.round(cpu * Resource.limit_ratio(:cpu), 3),
      "memory_mb" => Float.round(memory * Resource.limit_ratio(:memory), 3),
      "disk_mb" => Float.round(disk * Resource.limit_ratio(:disk), 3),
      "gpu_count" => floor(gpu * Resource.limit_ratio(:gpu))
    }
  end

  defp memory_capacity_mb(memory) do
    available = number_value(map_get(memory, "available_mb"))
    total = number_value(map_get(memory, "total_mb"))

    bytes =
      number_value(map_get(memory, "available_bytes")) ||
        number_value(map_get(memory, "total_bytes"))

    cond do
      is_number(available) and available > 0 -> available
      is_number(total) and total > 0 -> total
      is_number(bytes) and bytes > 0 -> bytes / (1024 * 1024)
      true -> 0
    end
  end

  defp disk_capacity_mb(disk) do
    available = number_value(map_get(disk, "available_mb"))
    total = number_value(map_get(disk, "total_mb"))

    bytes =
      number_value(map_get(disk, "available_bytes")) || number_value(map_get(disk, "total_bytes"))

    cond do
      is_number(available) and available > 0 -> available
      is_number(total) and total > 0 -> total
      is_number(bytes) and bytes > 0 -> bytes / (1024 * 1024)
      true -> 0
    end
  end

  defp requirements_summary(demands) do
    demands
    |> Enum.map(& &1["resources"])
    |> Enum.reduce(empty_resources(), &add_resources/2)
  end

  defp add_resources(left, right) do
    Map.new(@resource_keys, fn key ->
      {key, (Map.get(left, key, 0) || 0) + (Map.get(right, key, 0) || 0)}
    end)
  end

  defp number_value(value) when is_integer(value), do: value
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_value), do: nil

  defp gpu_count(gpus) when is_list(gpus), do: length(gpus)

  defp gpu_count(gpu) when is_binary(gpu) do
    if unknown_gpu?(gpu), do: 0, else: 1
  end

  defp gpu_count(gpu) when is_map(gpu), do: 1
  defp gpu_count(_gpu), do: 0

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(gpu)

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      existing_atom_value(map, key)
    end
  end

  defp map_get(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    atom = String.to_existing_atom(key)
    if Map.has_key?(map, atom), do: Map.get(map, atom)
  rescue
    ArgumentError -> nil
  end

  defp list_value(value) when is_list(value), do: Enum.map(value, &to_string/1)

  defp list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_value(value) when is_nil(value), do: []
  defp list_value(value), do: [to_string(value)]

  defp truthy?(value) when value in [true, "true", "TRUE", "True", "1", 1, "yes", "on"],
    do: true

  defp truthy?(_value), do: false

  defp eligible_value(nil), do: true
  defp eligible_value(value) when value in [false, "false", "FALSE", "False", "0", 0], do: false
  defp eligible_value(_value), do: true

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp get_path(value, []), do: value

  defp get_path(map, [part | rest]) when is_map(map) do
    map
    |> map_get(part)
    |> get_path(rest)
  end

  defp get_path(_value, _parts), do: nil
end
