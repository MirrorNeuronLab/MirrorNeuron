defmodule PatchJobCoordinator do
  def run do
    content = File.read!("lib/mirror_neuron/runtime/job_coordinator.ex")

    new_init = """
  @impl true
  def init({job_id, manifest, opts}) do
    bundle = Keyword.get(opts, :job_bundle)

    existing_job =
      case RedisStore.fetch_job(job_id) do
        {:ok, job_map} when is_map(job_map) -> job_map
        _ -> nil
      end

    status = if existing_job, do: existing_job["status"], else: "pending"
    submitted_at = if existing_job, do: existing_job["submitted_at"], else: Runtime.timestamp()
    result = if existing_job, do: existing_job["result"], else: nil

    state = %{
      job_id: job_id,
      manifest: manifest,
      bundle: bundle,
      opts: opts,
      status: status,
      result: result,
      submitted_at: submitted_at,
      agent_ids: Enum.map(manifest.nodes, & &1.node_id),
      nodes_by_id: Map.new(manifest.nodes, &{&1.node_id, &1}),
      outbound_edges_by_node: Enum.group_by(manifest.edges, & &1.from_node),
      inbound_edges_by_node: Enum.group_by(manifest.edges, & &1.to_node),
      agent_restart_attempts: %{},
      max_agent_restart_attempts:
        Map.get(
          manifest.policies,
          "max_agent_restart_attempts",
          @default_max_agent_restart_attempts
        ),
      health_check_interval_ms:
        Application.get_env(
          :mirror_neuron,
          :job_health_check_interval_ms,
          @default_health_check_interval_ms
        )
    }

    if status == "pending" do
      persist_job(state)
      EventBus.publish(job_id, %{type: :job_pending, timestamp: Runtime.timestamp()})
      {:ok, state, {:continue, :bootstrap}}
    else
      # Recovering existing job
      EventBus.publish(job_id, %{type: :job_recovery_started, timestamp: Runtime.timestamp()})
      {:ok, state, {:continue, :recover}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    schedule_health_check(100) # trigger immediate health check to recover missing agents
    {:noreply, state}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
"""
    new_content = String.replace(content, ~r/@impl true\n  def init.*?@impl true\n  def handle_continue\(:bootstrap, state\) do/s, new_init)
    File.write!("lib/mirror_neuron/runtime/job_coordinator.ex", new_content)
  end
end
PatchJobCoordinator.run()
