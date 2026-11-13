defmodule MirrorNeuron.Runtime.BackpressureTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.Backpressure

  test "config ignores malformed override options" do
    assert %{max_queue_depth: 100, high_watermark: 75, low_watermark: 25} =
             Backpressure.config(%{}, :not_options)

    assert %{max_queue_depth: 100, high_watermark: 75, low_watermark: 25} =
             Backpressure.config(%{}, [:bad_option])
  end

  test "process queue depth falls back to internal depth for dead processes" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert Backpressure.process_queue_depth(pid, 4) == 4
  end

  test "process queue depth includes live mailbox and internal depth" do
    pid = spawn(fn -> Process.sleep(1_000) end)

    try do
      send(pid, :one)
      send(pid, :two)

      assert Backpressure.process_queue_depth(pid, 3) >= 5
    after
      Process.exit(pid, :kill)
    end
  end
end
