defmodule MirrorNeuron.RedisTest do
  use ExUnit.Case, async: false

  test "reconnect does not crash when supervisor is stopping" do
    redis_pid = Process.whereis(MirrorNeuron.Redis)
    assert is_pid(redis_pid)

    ref = Process.monitor(redis_pid)
    Supervisor.stop(redis_pid)

    assert_receive {:DOWN, ^ref, :process, ^redis_pid, _reason}
    assert MirrorNeuron.Redis.reconnect() in [{:error, :not_running}, :ok]

    restart_redis_child()

    assert_eventually(fn -> ping?() end)
  end

  test "concurrent reconnect callers perform one complete child transition" do
    old_connection = Process.whereis(MirrorNeuron.Redis.Connection)
    parent = self()

    tasks =
      for _index <- 1..32 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :reconnect -> MirrorNeuron.Redis.reconnect(old_connection)
          end
        end)
      end

    callers =
      for _index <- tasks do
        assert_receive {:ready, caller}
        caller
      end

    Enum.each(callers, &send(&1, :reconnect))
    assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == :ok))

    assert_eventually(fn -> ping?() end)
    new_connection = Process.whereis(MirrorNeuron.Redis.Connection)
    assert is_pid(new_connection)
    refute new_connection == old_connection

    assert MirrorNeuron.Redis.reconnect(old_connection) == :ok
    assert Process.whereis(MirrorNeuron.Redis.Connection) == new_connection
  end

  defp ping? do
    match?({:ok, "PONG"}, Redix.command(MirrorNeuron.Redis.Connection, ["PING"]))
  catch
    :exit, _reason -> false
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  defp restart_redis_child do
    case Supervisor.restart_child(MirrorNeuron.Supervisor, MirrorNeuron.Redis) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
