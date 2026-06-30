defmodule MirrorNeuron.Runtime.HordeCluster do
  @moduledoc false

  use GenServer
  require Logger

  @refresh_ms 2_000
  @hordes [
    MirrorNeuron.DistributedRegistry,
    MirrorNeuron.Runtime.JobSupervisor,
    MirrorNeuron.Runtime.AgentSupervisor
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def initial_members(horde), do: horde_members(horde, [Node.self()])

  def horde_members(horde, nodes) do
    nodes
    |> Enum.uniq()
    |> Enum.map(&{horde, &1})
  end

  def member_nodes(self_node, connected_nodes, configured_nodes) do
    configured = configured_set(configured_nodes)
    self_prefix = node_prefix(self_node)

    [self_node | connected_nodes]
    |> Enum.uniq()
    |> Enum.filter(&runtime_node?(&1, self_node, self_prefix, configured))
  end

  @impl true
  def init(opts) do
    if distributed?() do
      :net_kernel.monitor_nodes(true)
      send(self(), :refresh)
    end

    {:ok, %{refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms)}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh_members()
    {:noreply, state}
  end

  def handle_info({event, _node}, state) when event in [:nodeup, :nodedown] do
    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_members do
    configured = configured_nodes()
    connect_configured_nodes(configured)

    nodes = member_nodes(Node.self(), Node.list(), configured)

    Enum.each(@hordes, fn horde ->
      case Horde.Cluster.set_members(horde, horde_members(horde, nodes)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "failed to update Horde members for #{inspect(horde)}: #{inspect(reason)}"
          )
      end
    end)
  rescue
    error ->
      Logger.warning("failed to refresh Horde cluster membership: #{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("failed to refresh Horde cluster membership: #{inspect({kind, reason})}")
  end

  defp connect_configured_nodes(nodes) do
    Enum.each(nodes, fn node ->
      if node != Node.self(), do: Node.connect(node)
    end)
  end

  defp configured_nodes do
    "MN_CLUSTER_NODES"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn raw ->
      case MirrorNeuron.SafeAccess.node_name_to_atom(String.trim(raw)) do
        {:ok, node} -> [node]
        {:error, _reason} -> []
      end
    end)
  end

  defp configured_set(nodes) do
    nodes
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp runtime_node?(node, self_node, self_prefix, configured) do
    node == self_node or MapSet.member?(configured, to_string(node)) or
      node_prefix(node) == self_prefix
  end

  defp node_prefix(node) do
    node
    |> to_string()
    |> String.split("@", parts: 2)
    |> List.first()
  end

  defp distributed?, do: Node.self() != :nonode@nohost
end
