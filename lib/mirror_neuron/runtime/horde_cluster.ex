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

  @doc false
  def refresh do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :refresh)

    :ok
  end

  @doc false
  def configured_nodes do
    (env_configured_nodes() ++ persisted_configured_nodes())
    |> Enum.uniq()
  end

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
    enabled = distributed?()

    if enabled do
      :net_kernel.monitor_nodes(true)
    end

    state = %{
      enabled: enabled,
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      refresh_timer_ref: nil,
      refresh_token: nil,
      memberships: %{}
    }

    {:ok, if(enabled, do: schedule_refresh(state, 0), else: state)}
  end

  @impl true
  def handle_info({event, _node}, %{enabled: true} = state)
      when event in [:nodeup, :nodedown] do
    {:noreply, state |> Map.put(:memberships, %{}) |> schedule_refresh()}
  end

  def handle_info({event, _node}, state) when event in [:nodeup, :nodedown],
    do: {:noreply, state}

  def handle_info({:refresh, token}, %{enabled: true, refresh_token: token} = state) do
    state = clear_refresh_timer(state)
    {:noreply, state |> refresh_members() |> schedule_refresh()}
  end

  def handle_info({:refresh, _stale_token}, state), do: {:noreply, state}

  def handle_info(:refresh, %{enabled: true} = state) do
    {:noreply, refresh_members(state)}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh, %{enabled: true} = state) do
    {:noreply, state |> refresh_members() |> schedule_refresh()}
  end

  def handle_cast(:refresh, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_refresh(state)
    :ok
  end

  @doc false
  def refresh_horde_memberships(hordes, nodes, previous, opts \\ []) do
    set_members = Keyword.get(opts, :set_members, &Horde.Cluster.set_members/2)
    whereis = Keyword.get(opts, :whereis, &Process.whereis/1)

    Enum.reduce(hordes, previous, fn horde, memberships ->
      members = horde_members(horde, nodes)
      signature = {whereis.(horde), MapSet.new(members)}

      if Map.get(memberships, horde) == signature do
        memberships
      else
        case safely_set_members(set_members, horde, members) do
          :ok -> Map.put(memberships, horde, signature)
          :error -> memberships
        end
      end
    end)
  end

  defp refresh_members(state) do
    configured = configured_nodes()
    connect_configured_nodes(configured)

    nodes =
      Node.self()
      |> member_nodes(Node.list(), configured)
      |> Enum.sort_by(&to_string/1)

    memberships = refresh_horde_memberships(@hordes, nodes, state.memberships)
    %{state | memberships: memberships}
  rescue
    error ->
      Logger.warning("failed to refresh Horde cluster membership: #{Exception.message(error)}")
      state
  catch
    kind, reason ->
      Logger.warning("failed to refresh Horde cluster membership: #{inspect({kind, reason})}")
      state
  end

  defp safely_set_members(set_members, horde, members) do
    case set_members.(horde, members) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to update Horde members for #{inspect(horde)}: #{inspect(reason)}")
        :error

      other ->
        Logger.warning("failed to update Horde members for #{inspect(horde)}: #{inspect(other)}")

        :error
    end
  rescue
    error ->
      Logger.warning(
        "failed to update Horde members for #{inspect(horde)}: #{Exception.message(error)}"
      )

      :error
  catch
    kind, reason ->
      Logger.warning(
        "failed to update Horde members for #{inspect(horde)}: #{inspect({kind, reason})}"
      )

      :error
  end

  defp connect_configured_nodes(nodes) do
    Enum.each(nodes, fn node ->
      if node != Node.self(), do: Node.connect(node)
    end)
  end

  defp schedule_refresh(state, delay_ms \\ nil) do
    state = cancel_refresh(state)
    token = make_ref()
    ref = Process.send_after(self(), {:refresh, token}, delay_ms || state.refresh_ms)
    %{state | refresh_timer_ref: ref, refresh_token: token}
  end

  defp cancel_refresh(%{refresh_timer_ref: ref, refresh_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:refresh, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_refresh_timer(state)
  end

  defp cancel_refresh(state), do: state

  defp clear_refresh_timer(state),
    do: %{state | refresh_timer_ref: nil, refresh_token: nil}

  defp env_configured_nodes do
    "MN_CLUSTER_NODES"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.flat_map(&node_name_to_atom/1)
  end

  defp persisted_configured_nodes do
    MirrorNeuron.Cluster.NodeState.list()
    |> Enum.flat_map(fn
      %{"connection_mode" => "federated"} ->
        []

      %{"node" => node_name, "status" => status}
      when status in ["healthy", "joining"] ->
        node_name_to_atom(node_name)

      _state ->
        []
    end)
  rescue
    _ -> []
  end

  defp node_name_to_atom(raw) do
    case MirrorNeuron.SafeAccess.node_name_to_atom(String.trim(to_string(raw))) do
      {:ok, node} -> [node]
      {:error, _reason} -> []
    end
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
