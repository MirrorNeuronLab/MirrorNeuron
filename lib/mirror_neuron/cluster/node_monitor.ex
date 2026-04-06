defmodule MirrorNeuron.Cluster.NodeMonitor do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.notice("Node joined cluster: #{node}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.notice("Node left cluster: #{node}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
