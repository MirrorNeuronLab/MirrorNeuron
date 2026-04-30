defmodule MirrorNeuron.Redis do
  use Supervisor

  alias MirrorNeuron.Config
  alias MirrorNeuron.Redis.Sentinel

  def start_link(_arg) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [redix_child_spec()]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def connection_url(resolve_sentinel \\ &Sentinel.resolve_primary_url/0) do
    if Sentinel.enabled?() do
      case resolve_sentinel.() do
        {:ok, url} ->
          url

        {:error, reason} ->
          raise "could not resolve Redis Sentinel primary: #{inspect(reason)}"
      end
    else
      Config.string("MIRROR_NEURON_REDIS_URL", :redis_url)
    end
  end

  def reconnect do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      _pid ->
        restart_child()
    end
  end

  def reconnectable_error?(%Redix.ConnectionError{}), do: true

  def reconnectable_error?(%Redix.Error{message: message}) when is_binary(message) do
    message
    |> String.upcase()
    |> String.contains?("READONLY")
  end

  def reconnectable_error?({:redix_exited_during_call, _reason}), do: true
  def reconnectable_error?({:redix_exit, _reason}), do: true
  def reconnectable_error?(_reason), do: false

  defp restart_child do
    with :ok <- stop_child(),
         :ok <- delete_child() do
      start_child()
    end
  end

  defp stop_child do
    case Supervisor.terminate_child(__MODULE__, :redix) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_started} -> :ok
      {:error, :restarting} -> :ok
      other -> other
    end
  end

  defp delete_child do
    case Supervisor.delete_child(__MODULE__, :redix) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp start_child do
    child_spec = redix_child_spec()

    case Supervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  rescue
    exception -> {:error, exception}
  end

  defp redix_child_spec do
    %{
      id: :redix,
      start: {Redix, :start_link, [connection_url(), [name: __MODULE__.Connection]]}
    }
  end
end
