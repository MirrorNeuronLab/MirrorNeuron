defmodule PatchJobRunner do
  def run do
    content = File.read!("lib/mirror_neuron/runtime/job_runner.ex")
    # We want to add lease refreshing in JobRunner.
    # JobRunner init:
    new_init = """
  @impl true
  def init({job_id, manifest, opts}) do
    Process.flag(:trap_exit, true)

    lease_name = "job:\#{job_id}"
    node_name = to_string(Node.self())

    case RedisStore.acquire_lease(lease_name, node_name, 10_000) do
      :ok -> :ok
      {:error, :locked} -> 
        # try to see if we already own it (Horde restart logic)
        case RedisStore.renew_lease(lease_name, node_name, 10_000) do
           :ok -> :ok
           {:error, _} -> exit(:normal) # someone else has it
        end
      _ -> :ok
    end

    :timer.send_interval(3_000, :renew_lease)

    case JobCoordinator.start_link({job_id, manifest, opts}) do
      {:ok, pid} ->
        {:ok,
         %{
           job_id: job_id,
           manifest: manifest,
           bundle: Keyword.get(opts, :job_bundle),
           coordinator: pid,
           node_name: node_name
         }}

      {:error, reason} ->
        Logger.warning("failed to start job coordinator for \#{job_id}: \#{inspect(reason)}")
        persist_runner_failure(job_id, manifest, Keyword.get(opts, :job_bundle), reason)
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:renew_lease, state) do
    lease_name = "job:\#{state.job_id}"
    case RedisStore.renew_lease(lease_name, state.node_name, 10_000) do
      :ok -> {:noreply, state}
      {:error, :not_owner} ->
        Logger.warning("Lost lease for job \#{state.job_id}. Shutting down.")
        {:stop, :normal, state}
      _ -> {:noreply, state}
    end
  end
"""
    new_content = String.replace(content, ~r/@impl true\n  def init\(\{job_id, manifest, opts\}\) do.*?end\n/s, new_init)
    File.write!("lib/mirror_neuron/runtime/job_runner.ex", new_content)
  end
end
PatchJobRunner.run()
