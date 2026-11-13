defmodule MirrorNeuron.Runtime.ErrorMonitor do
  @moduledoc "One supervised exit observer per worker, independent of coordinator callbacks."
  use DynamicSupervisor
  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def watch(pid, run_id, agent_id) do
    if Process.whereis(__MODULE__) do
      DynamicSupervisor.start_child(__MODULE__, {__MODULE__.Observer, {pid, run_id, agent_id}})
    end

    :ok
  end

  def expect_exit(pid) when node(pid) != node(),
    do: :rpc.call(node(pid), __MODULE__, :expect_exit, [pid], 1000)

  def expect_exit(pid) do
    if Process.whereis(__MODULE__.Registry) do
      for {_observer, expected} <- Registry.lookup(__MODULE__.Registry, pid),
          do: :atomics.put(expected, 1, 1)
    end

    :ok
  end
end

defmodule MirrorNeuron.Runtime.ErrorMonitor.Observer do
  use GenServer, restart: :temporary
  alias MirrorNeuron.Runtime.{ErrorMonitor, Signals}
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init({pid, run_id, agent_id}) do
    expected = :atomics.new(1, [])
    {:ok, _} = Registry.register(ErrorMonitor.Registry, pid, expected)
    {:ok, {Process.monitor(pid), run_id, agent_id, expected}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, {ref, run_id, agent_id, expected} = state) do
    if :atomics.get(expected, 1) == 0 and reason not in [:normal, :shutdown] and
         not match?({:shutdown, _}, reason),
       do: Signals.error(run_id, agent_id, "worker-exit", reason)

    {:stop, :normal, state}
  end
end
