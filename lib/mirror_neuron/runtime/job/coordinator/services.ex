defmodule MirrorNeuron.Runtime.JobCoordinator.Services do
  @moduledoc "Publishes service discovery records for ready runtime workers."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCoordinator.Context
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Scheduler
  alias MirrorNeuron.ServiceRegistry
  alias MirrorNeuron.ServiceSpec

  def register_runtime_services(state) do
    with :ok <- register_job_services(state) do
      Enum.reduce_while(state.agent_ids, :ok, fn agent_id, :ok ->
        case register_agent_services(state, agent_id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def register_job_services(state) do
    services =
      ServiceSpec.service_instances_for_job(state.manifest, state.job_id,
        bundle_root: Context.runtime_bundle_root(state)
      )

    register_services(state, services)
  end

  def register_agent_services(state, agent_id) do
    node = Map.fetch!(state.nodes_by_id, agent_id)
    plan = Topology.scheduler_plan(state)
    target_node = Scheduler.target_node(plan, agent_id) || to_string(Node.self())
    node_config = Map.get(node, :config, %{})

    service_environment =
      state
      |> Context.runtime_environment()
      |> Map.merge(
        node_config
        |> then(&(Map.get(&1, "environment") || Map.get(&1, :environment) || %{}))
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
      )

    services =
      ServiceSpec.service_instances_for_agent(
        state.manifest,
        state.job_id,
        node,
        target_node,
        bundle_root: Context.runtime_bundle_root(state),
        allocation: Scheduler.allocation(plan, agent_id),
        env: service_environment
      )

    register_services(state, services)
  end

  defp register_services(_state, []), do: :ok

  defp register_services(state, services) do
    services = Enum.map(services, &put_service_deployment_context(&1, state.deployment_context))

    case ServiceRegistry.register_many(services) do
      {:ok, registered} ->
        Enum.each(registered, fn service ->
          EventBus.publish(state.job_id, %{
            type: :service_registered,
            service_id: Map.get(service, "id"),
            service_name: Map.get(service, "name"),
            agent_id: Map.get(service, "agent_id"),
            node: Map.get(service, "node"),
            status: Map.get(service, "status"),
            timestamp: Runtime.timestamp()
          })
        end)

        :ok

      {:error, reason} ->
        {:error, "failed to register services: #{inspect(reason)}"}
    end
  end

  defp put_service_deployment_context(service, context)
       when is_map(context) and map_size(context) > 0 do
    service
    |> Map.put("deployment_id", Map.get(context, "deployment_id"))
    |> Map.put("deployment_key", Map.get(context, "deployment_key"))
    |> Map.put("deployment_version", Map.get(context, "deployment_version"))
    |> Map.put("deployment_role", Map.get(context, "deployment_role", "primary"))
  end

  defp put_service_deployment_context(service, _context), do: service

  def register_resumed_job_services(state) do
    if Topology.job_type(state) == "service", do: register_job_services(state), else: :ok
  end
end
