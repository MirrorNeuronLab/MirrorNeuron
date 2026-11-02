defmodule MirrorNeuron.Persistence.ProtectedRedis do
  @moduledoc "Independent Redis connections for protected traffic; failures are unconfirmed."
  use Supervisor
  @channels ["errors", "responses", "controls"]

  def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    children =
      for channel <- @channels do
        %{id: channel, start: {__MODULE__, :start_connection, [channel]}}
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  def start_connection(channel),
    do: Redix.start_link(MirrorNeuron.Redis.connection_url(), name: name(channel))

  defp name("errors"), do: __MODULE__.Errors
  defp name("responses"), do: __MODULE__.Responses
  defp name("controls"), do: __MODULE__.Controls

  def command(channel, args),
    do: call(channel, fn connection -> Redix.command(connection, args, timeout: 1000) end)

  def pipeline(channel, commands),
    do: call(channel, fn connection -> Redix.pipeline(connection, commands, timeout: 1000) end)

  def barrier(channel) do
    replicas = MirrorNeuron.Config.integer("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas)

    if replicas > 0 do
      case command(channel, [
             "WAIT",
             to_string(replicas),
             to_string(
               MirrorNeuron.Config.integer("MN_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms)
             )
           ]) do
        {:ok, n} when n >= replicas -> :ok
        other -> {:error, {:signal_replication_unconfirmed, other}}
      end
    else
      :ok
    end
  end

  def confirm_snapshot(channel) do
    if MirrorNeuron.Config.integer("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas) > 0 do
      # WAIT tracks this connection's last write. A fresh marker also fences
      # snapshots written by another connection or before a reconnect.
      key = MirrorNeuron.Persistence.RedisStore.storage_key(["signal_read_barrier", channel])

      with {:ok, "OK"} <- command(channel, ["SET", key, "1", "PX", "10000"]),
           do: barrier(channel)
    else
      :ok
    end
  end

  defp call(channel, fun) do
    result = fun.(name(channel))

    if match?({:error, %Redix.Error{}}, result) do
      {:error, error} = result

      if MirrorNeuron.Redis.reconnectable_error?(error) do
        if pid = Process.whereis(name(channel)), do: Process.exit(pid, :kill)
      end
    end

    result
  catch
    :exit, reason -> {:error, {:protected_store_unavailable, reason}}
  end
end
