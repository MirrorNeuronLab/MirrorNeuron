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

  test "repeated commands release every channel after success or RPC failure" do
    for result <- [{:ok, :committed}, {:error, :timeout}], _ <- 1..200 do
      rpc = fn channel, :request, opts ->
        send(self(), {:rpc, channel, opts})
        result
      end

      assert NativeSdkClient.call("native", :request, 1234, rpc, Transport) == result
      assert_receive {:connect, "native", [timeout: 1234]}
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

    assert_receive {:connect, "native", [timeout: 100]}
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
