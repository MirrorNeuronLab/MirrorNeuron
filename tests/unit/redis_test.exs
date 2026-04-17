defmodule MirrorNeuron.RedisTest do
  use ExUnit.Case, async: false

  test "reconnect does not crash when supervisor is stopping" do
    redis_pid = Process.whereis(MirrorNeuron.Redis)
    assert is_pid(redis_pid)

    ref = Process.monitor(redis_pid)
    Supervisor.stop(redis_pid)

    assert_receive {:DOWN, ^ref, :process, ^redis_pid, _reason}
    assert MirrorNeuron.Redis.reconnect() in [{:error, :not_running}, :ok]

    case MirrorNeuron.Redis.start_link(:ok) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    assert_eventually(fn ->
      match?({:ok, "PONG"}, Redix.command(MirrorNeuron.Redis.Connection, ["PING"]))
    end)
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
end
