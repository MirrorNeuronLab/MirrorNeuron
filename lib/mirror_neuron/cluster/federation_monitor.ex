defmodule MirrorNeuron.Cluster.FederationMonitor do
  @moduledoc false
  use GenServer

  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry}

  @interval 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def sync_now, do: GenServer.call(__MODULE__, :sync_now, 30_000)

  @impl true
  def init(:ok) do
    schedule(250)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {:reply, sync_all(), state}
  end

  @impl true
  def handle_info(:sync, state) do
    _ = sync_all()
    schedule(@interval)
    {:noreply, state}
  end

  # grpc-elixir's Gun transport can deliver asynchronous channel teardown
  # notifications to the process that opened a short-lived peer channel.
  # They are transport lifecycle messages, not monitor failures.
  def handle_info({event, _connection, _protocol, _reason, _streams}, state)
      when event in [:gun_down, :gun_up] do
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp sync_all do
    FederationRegistry.list()
    |> Enum.map(fn peer ->
      node_name = Map.get(peer, "node_name")
      {node_name, FederationClient.sync_peer(node_name)}
    end)
    |> Map.new()
  end

  defp schedule(delay), do: Process.send_after(self(), :sync, delay)
end
