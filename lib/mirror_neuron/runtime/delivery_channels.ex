defmodule MirrorNeuron.Runtime.DeliveryChannels do
  @moduledoc "Versioned delivery lanes. Only trusted runtime callers select a lane."
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.SafeAccess
  alias MirrorNeuron.Runtime.{Backpressure, Delivery}

  def supported_versions, do: [1, 2]

  # Polling happens even for idle agents. A guard is a small fenced record,
  # whereas the durable Job can contain megabytes of executable definitions.
  def settings(job) do
    manifest = SafeAccess.map_get(job, "manifest") || %{}
    topology = SafeAccess.map_get(job, "runtime_topology") || %{}

    nodes =
      manifest["nodes"] || get_in(manifest, ["flow", "nodes"]) ||
        get_in(manifest, ["agents", "nodes"]) || []

    source_limits =
      for node <- nodes,
          config = node["config"] || %{},
          pressure = config["backpressure"] || config,
          is_map(pressure) and Map.has_key?(pressure, "max_queue_depth"),
          into: %{},
          do: {node["node_id"], Backpressure.config(config).max_queue_depth}

    limits =
      Enum.reduce(topology["nodes"] || [], source_limits, fn node, acc ->
        case Map.fetch(source_limits, node["source_node_id"] || node["node_id"]) do
          {:ok, limit} -> Map.put(acc, node["node_id"], limit)
          :error -> acc
        end
      end)

    %{"version" => SafeAccess.map_get(job, "delivery_version", 1), "limits" => limits}
  end

  def version(job_id) do
    case RedisStore.fetch_delivery_settings(job_id) do
      {:ok, %{"version" => version}} when version in [1, 2] ->
        {:ok, version}

      {:ok, %{"version" => version}} ->
        {:error, {:unsupported_delivery_version, version}}

      {:error, reason} = error ->
        if reason == "job #{job_id} was not found", do: {:ok, 1}, else: error
    end
  end

  def bucket(agent_id, lane, 2) when lane in [:command, :control],
    do: "__mn_#{lane}__/" <> agent_id

  def bucket(agent_id, _lane, _version), do: agent_id

  def lane(agent_id, opts) do
    cond do
      agent_id == Delivery.coordinator_agent_id() -> :control
      Keyword.get(opts, :command_admitted, false) -> :command
      true -> :data
    end
  end

  def read_order(agent_id, streak) do
    if agent_id == Delivery.coordinator_agent_id(),
      do: [:control],
      else: if(streak >= 4, do: [:data, :command], else: [:command, :data])
  end

  def next_streak(:command, streak), do: min(streak + 1, 4)
  def next_streak(:data, _streak), do: 0
  def next_streak(_, streak), do: streak

  def depth(job_id, agent_id, lane \\ :data) do
    with {:ok, version} <- version(job_id),
         do: RedisStore.delivery_pending_count(job_id, bucket(agent_id, lane, version))
  end

  def limit(job_id, agent_id, opts) do
    with {:ok, %{"limits" => limits}} <- RedisStore.fetch_delivery_settings(job_id) do
      configured = Map.get(limits, agent_id, Backpressure.config(%{}).max_queue_depth)
      {:ok, min(configured, Keyword.get(opts, :max_queue_depth, configured))}
    end
  end
end
