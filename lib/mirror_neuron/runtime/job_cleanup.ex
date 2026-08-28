defmodule MirrorNeuron.Runtime.JobCleanup do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Runner.HostLocal
  alias MirrorNeuron.Runtime.RunnerResources
  alias MirrorNeuron.SafeAccess
  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}

  @cleanup_timeout_ms 15_000

  @runtime_resources [
    {HostLocal, :terminate_job, "HostLocal"},
    {OpenShellJobSandbox, :cleanup_job_local, "OpenShell"},
    {DockerJobSandbox, :cleanup_job_local, "DockerWorker"}
  ]

  @sandbox_resources [
    {HostLocal, :terminate_job, "HostLocal"},
    {OpenShellJobSandbox, :cleanup_job_local, "OpenShell"},
    {DockerJobSandbox, :cleanup_job_local, "DockerWorker"}
  ]

  def cleanup_runtime_resources(job_id, job, agents) when is_list(agents) do
    cleanup(job_id, job, agents, runtime_resources(job))
  end

  def cleanup_sandboxes(job_id, job, agents) when is_list(agents) do
    cleanup(job_id, job, agents, @sandbox_resources)
  end

  defp cleanup(job_id, job, agents, resources) do
    failures =
      job
      |> cleanup_nodes(agents)
      |> Enum.flat_map(fn node ->
        Enum.flat_map(resources, fn {module, function, label} ->
          case safe_cleanup_on_node(node, module, function, job_id) do
            :ok ->
              []

            reason ->
              Logger.warning(
                "failed to clean up #{label} resource for #{job_id} on #{node}: #{inspect(reason)}"
              )

              [%{node: to_string(node), resource: label, reason: reason}]
          end
        end)
      end)

    if failures == [], do: :ok, else: {:error, failures}
  end

  defp runtime_resources(job) do
    _ = job

    @runtime_resources ++
      [{RunnerResources, :cleanup_native_resources, "native SDK resources"}]
  end

  defp cleanup_nodes(job, agents) do
    connected_nodes = [NodeAdapter.self() | NodeAdapter.list()]

    placement_nodes =
      job
      |> detail("scheduler")
      |> detail("placements")
      |> case do
        placements when is_list(placements) -> Enum.map(placements, &detail(&1, "node"))
        _other -> []
      end

    assigned_nodes = Enum.map(agents, &detail(&1, "assigned_node"))

    (connected_nodes ++ placement_nodes ++ assigned_nodes)
    |> Enum.reduce([], fn value, nodes ->
      case cleanup_node(value) do
        {:ok, node} -> [node | nodes]
        :error -> nodes
      end
    end)
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp cleanup_node(node) when is_atom(node), do: {:ok, node}

  defp cleanup_node(node) when is_binary(node) do
    case SafeAccess.node_name_to_atom(node) do
      {:ok, atom} -> {:ok, atom}
      {:error, _reason} -> :error
    end
  end

  defp cleanup_node(_node), do: :error

  defp safe_cleanup_on_node(node, module, function, job_id) do
    NodeAdapter.rpc_call(node, module, function, [job_id], @cleanup_timeout_ms)
  rescue
    exception -> {:badrpc, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:badrpc, {kind, reason}}
  end

  defp detail(nil, _key), do: nil
  defp detail(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, safe_atom(key))
  defp detail(_other, _key), do: nil

  defp safe_atom("scheduler"), do: :scheduler
  defp safe_atom("placements"), do: :placements
  defp safe_atom("node"), do: :node
  defp safe_atom("assigned_node"), do: :assigned_node
  defp safe_atom(_key), do: nil
end
