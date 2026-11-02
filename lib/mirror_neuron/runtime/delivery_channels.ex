defmodule MirrorNeuron.Runtime.DeliveryChannels do
  @moduledoc "Versioned delivery lanes. Only trusted runtime callers select a lane."
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{Backpressure, Delivery}

  def supported_versions, do: [1, 2]

  def version(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} ->
        version = Map.get(job, "delivery_version", 1)

        if version in [1, 2],
          do: {:ok, version},
          else: {:error, {:unsupported_delivery_version, version}}

      {:error, reason} = error when is_binary(reason) ->
        if reason == "job #{job_id} was not found", do: {:ok, 1}, else: error

      error ->
        error
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
    case RedisStore.fetch_job(job_id) do
      {:ok, job} ->
        nodes = get_in(job, ["manifest", "nodes"]) || []
        topology = get_in(job, ["runtime_topology", "nodes"]) || []

        source =
          Enum.find(topology, %{}, &(&1["node_id"] == agent_id))["source_node_id"] || agent_id

        node = Enum.find(nodes, %{}, &(&1["node_id"] == source))
        configured = Backpressure.config(node["config"] || %{}).max_queue_depth
        supplied = Keyword.get(opts, :max_queue_depth, configured)
        {:ok, min(configured, supplied)}

      error ->
        error
    end
  end
end
