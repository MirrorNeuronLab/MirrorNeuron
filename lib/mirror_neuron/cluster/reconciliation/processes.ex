defmodule MirrorNeuron.Cluster.Reconciler.Processes do
  @moduledoc "Stops prior coordinators, releases fenced leases and starts supervised job runners."

  alias MirrorNeuron.Runtime.JobRunner
  alias MirrorNeuron.Cluster.Reconciler.Jobs
  alias MirrorNeuron.Cluster.Reconciler.Options

  def start_job_runner(job_id, bundle, job, scheduler_plan, opts) do
    wait_for_existing_runner_stopped(job_id, opts)

    runner =
      Keyword.get(opts, :start_job_runner, fn start_job_id, start_bundle, start_opts ->
        spec = {JobRunner, {start_job_id, start_bundle.manifest, start_opts}}

        start_supervised_job(spec, Keyword.get(start_opts, :preferred_start_node))
      end)

    runner_opts =
      [
        job_bundle: bundle,
        bundle_ref: job["manifest_ref"],
        run_id: job["run_id"] || job_id,
        stable_job_id: job["stable_job_id"],
        job_data_dir: job["job_data_dir"],
        job_data_access: job["job_data_access"],
        data_generation: job["data_generation"],
        requested_recovery_policy: job["requested_recovery_policy"],
        recovery_policy: job["recovery_policy"],
        reliability: job["reliability"],
        scheduler_plan: scheduler_plan,
        preferred_start_node: Keyword.get(opts, :preferred_start_node),
        restart_reason: Keyword.get(opts, :restart_reason)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    runner.(job_id, bundle, runner_opts)
  end

  defp start_supervised_job(spec, nil), do: start_supervised_job_here(spec)

  defp start_supervised_job(spec, preferred_node) when is_binary(preferred_node) do
    case MirrorNeuron.SafeAccess.node_name_to_atom(preferred_node) do
      {:ok, node} -> start_supervised_job(spec, node)
      {:error, _reason} -> start_supervised_job_here(spec)
    end
  end

  defp start_supervised_job(spec, preferred_node) when is_atom(preferred_node) do
    if preferred_node != Node.self() and Node.connect(preferred_node) do
      case :rpc.call(
             preferred_node,
             Horde.DynamicSupervisor,
             :start_child,
             [MirrorNeuron.Runtime.JobSupervisor, spec],
             30_000
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
        {:badrpc, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      start_supervised_job_here(spec)
    end
  end

  defp start_supervised_job_here(spec) do
    case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_existing_coordinator(job_id, opts) do
    case coordinator_pid(job_id, opts) do
      {:ok, pid} ->
        GenServer.stop(pid, :normal, 10_000)

      :not_found ->
        :ok
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp wait_for_existing_runner_stopped(job_id, opts) do
    timeout_ms = Keyword.get(opts, :existing_runner_stop_timeout_ms, 12_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_existing_runner_stopped(job_id, deadline)
  end

  defp do_wait_for_existing_runner_stopped(job_id, deadline) do
    registrations =
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) ++
        Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id})

    case registrations do
      [] ->
        :ok

      _entries ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(100)
          do_wait_for_existing_runner_stopped(job_id, deadline)
        end
    end
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  def release_job_lease(job_id, job, opts) do
    owner = Jobs.lease_owner(job)
    epoch = job["lease_epoch"] || get_in(job, ["lease", "epoch"])
    store = Options.redis_store(opts)

    cond do
      is_binary(owner) and not is_nil(epoch) and
          function_exported?(store, :release_fenced_lease, 3) ->
        _ = store.release_fenced_lease("job:#{job_id}", owner, epoch)
        :ok

      is_binary(owner) and function_exported?(store, :release_lease, 2) ->
        _ = store.release_lease("job:#{job_id}", owner)
        :ok

      true ->
        :ok
    end
  end

  defp coordinator_pid(job_id, opts) do
    case Keyword.get(opts, :lookup_coordinator) do
      lookup when is_function(lookup, 1) ->
        lookup.(job_id)

      _ ->
        case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
          [{pid, _meta}] when is_pid(pid) -> {:ok, pid}
          _ -> :not_found
        end
    end
  end
end
