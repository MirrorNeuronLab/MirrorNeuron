defmodule MirrorNeuron.Runtime.RunLifecycle do
  @moduledoc "Generation-fenced readiness shared by all runner implementations."
  alias MirrorNeuron.Runner
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.JobCoordinator.Snapshots

  def new(nodes, generation \\ nil) do
    services =
      for node <- nodes,
          Runner.control_profile(node.config).readiness == :reported,
          do: node.node_id

    %{
      "generation" => generation || Base.encode16(:crypto.strong_rand_bytes(16)),
      "required" => services,
      "services" => %{}
    }
  end

  def ready?(lifecycle) when is_map(lifecycle) do
    Enum.all?(lifecycle["required"] || [], fn id ->
      get_in(lifecycle, ["services", id, "state"]) == "serving"
    end)
  end

  def ready?(_), do: false

  def observe(state, agent_id, "service_lifecycle", payload) do
    receipt = if is_map(payload) and is_map(payload["details"]), do: payload["details"], else: %{}
    lifecycle = state.lifecycle
    previous = get_in(lifecycle, ["services", agent_id]) || %{}

    if state.status == "running" and agent_id in lifecycle["required"] and
         receipt["control_generation"] == lifecycle["generation"] and
         receipt["service_id"] == agent_id and
         receipt["state"] in ~w(starting serving stopping stopped failed) and
         is_binary(receipt["generation"]) and is_integer(receipt["sequence"]) and
         (receipt["generation"] != previous["generation"] or
            receipt["sequence"] > (previous["sequence"] || 0)) do
      receipt = Map.take(receipt, ["state", "generation", "sequence"])
      next = put_in(state.lifecycle["services"][agent_id], receipt)
      # Readiness is a control boundary, not a best-effort UI projection.
      case RedisStore.persist_job(next.job_id, Snapshots.job_snapshot(next)) do
        {:ok, _} -> next
        {:error, reason} -> exit({:shutdown, {:lifecycle_persistence_failed, reason}})
      end
    else
      state
    end
  end

  def observe(state, _, _, _), do: state
end
