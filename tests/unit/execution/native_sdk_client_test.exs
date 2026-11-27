defmodule MirrorNeuron.NativeSdkClientTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.NativeSdkClient

  defmodule Transport do
    def connect(target, opts) do
      send(self(), {:connect, target, opts})
      if target == "unavailable", do: {:error, :timeout}, else: {:ok, make_ref()}
    end

    def disconnect(channel), do: send(self(), {:disconnect, channel})
  end

  defmodule SharedTransport do
    def connect({:delayed, owner}, _opts) do
      send(owner, {:connecting, self()})

      receive do
        :finish -> {:error, :closed}
      after
        1000 -> {:error, :timeout}
      end
    end

    def connect(_target, _opts), do: {:ok, self()}
  end

  test "an expired channel checkout returns a timeout without dispatching" do
    pool = start_supervised!(MirrorNeuron.Cluster.FederationChannels)
    rpc = fn _, _, _ -> flunk("must not dispatch after checkout expires") end

    assert {:error, :timeout} =
             NativeSdkClient.call_shared(
               {:delayed, self()},
               :request,
               10,
               rpc,
               pool,
               SharedTransport
             )

    assert_receive {:connecting, worker}
    send(worker, :finish)
  end

  test "resource callbacks reuse the channel and retire it after a transport failure" do
    owner = self()

    pool =
      start_supervised!(
        {MirrorNeuron.Cluster.FederationChannels,
         disconnect: fn channel -> send(owner, {:closed, channel}) end}
      )

    rpc = fn channel, result, _opts ->
      send(owner, {:called, channel})
      result
    end

    call = &NativeSdkClient.call_shared("native", &1, 1000, rpc, pool, SharedTransport)
    assert {:ok, 1} = call.({:ok, 1})
    assert_receive {:called, first}
    assert {:ok, 2} = call.({:ok, 2})
    assert_receive {:called, ^first}
    assert {:error, :closed} = call.({:error, :closed})
    assert_receive {:called, ^first}
    assert_receive {:closed, ^first}
    assert {:ok, 3} = call.({:ok, 3})
    assert_receive {:called, next}
    refute next == first
    refute_received {:called, _}
  end

  test "repeated commands release every channel after success or RPC failure" do
    for result <- [{:ok, :committed}, {:error, :timeout}], _ <- 1..200 do
      rpc = fn channel, :request, opts ->
        send(self(), {:rpc, channel, opts})
        result
      end

      assert NativeSdkClient.call("native", :request, 1234, rpc, Transport) == result
      assert_receive {:connect, "native", connection_opts}
      assert connection_opts[:timeout] == 1234
      assert_receive {:rpc, channel, [timeout: 1234]}
      assert_receive {:disconnect, ^channel}
      refute_receive {:connect, _, _}, 0
      refute_receive {:disconnect, _}, 0
    end
  end

  test "an exception still releases the channel without replaying the command" do
    rpc = fn channel, _, _ ->
      send(self(), {:rpc, channel})
      raise "native failure"
    end

    assert_raise RuntimeError, "native failure", fn ->
      NativeSdkClient.call("native", :request, 100, rpc, Transport)
    end

    assert_receive {:connect, "native", connection_opts}
    assert connection_opts[:timeout] == 100
    assert_receive {:rpc, channel}
    assert_receive {:disconnect, ^channel}
    refute_receive {:rpc, _}, 0
  end

  test "a failed connection dispatches nothing and preserves its failure" do
    rpc = fn _, _, _ -> flunk("must not dispatch after connection failure") end

    assert {:error, :timeout} =
             NativeSdkClient.call("unavailable", :request, 100, rpc, Transport)

    refute_receive {:disconnect, _}, 0
  end
end
