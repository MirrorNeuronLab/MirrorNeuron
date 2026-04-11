defmodule MirrorNeuron.Redis do
  use Supervisor

  alias MirrorNeuron.Config

  def start_link(_arg) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    redis_url = Config.string("MIRROR_NEURON_REDIS_URL", :redis_url)

    children = [
      %{
        id: :redix,
        start: {Redix, :start_link, [redis_url, [name: __MODULE__.Connection]]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def reconnect do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      _pid ->
        case Supervisor.terminate_child(__MODULE__, :redix) do
          :ok ->
            restart_child()

          {:error, :not_found} ->
            restart_child()

          {:error, :restarting} ->
            :ok

          {:error, :not_started} ->
            restart_child()

          other ->
            other
        end
    end
  end

  defp restart_child do
    case Supervisor.restart_child(__MODULE__, :redix) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
      other -> other
    end
  end
end
