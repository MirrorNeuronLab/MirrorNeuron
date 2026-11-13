defmodule MirrorNeuron.Runtime.StableJob.StartGateTest do
  use MirrorNeuron.RuntimeCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob

  test "callback exceptions release the definition gate", %{id: id} do
    assert_raise RuntimeError, "expected callback failure", fn ->
      StableJob.with_start_gate(id, fn -> raise "expected callback failure" end)
    end

    assert {:ok, nil} = RedisStore.get_lease("job-data-start:#{id}")
    assert :recovered = StableJob.with_start_gate(id, fn -> :recovered end)
  end

  test "callback error receipts are preserved and release the gate", %{id: id} do
    assert {:error, :validation_failed} =
             StableJob.with_start_gate(id, fn -> {:error, :validation_failed} end)

    assert {:ok, nil} = RedisStore.get_lease("job-data-start:#{id}")
  end

  test "a blocked definition callback cannot block an unrelated Job", %{id: id} do
    parent = self()

    task =
      Task.async(fn ->
        StableJob.with_start_gate(id, fn ->
          send(parent, :gate_acquired)

          receive do
            :release -> :finished
          after
            5_000 -> {:error, :test_release_timeout}
          end
        end)
      end)

    assert_receive :gate_acquired, 1_000
    assert :independent = StableJob.with_start_gate("other-#{id}", fn -> :independent end)
    send(task.pid, :release)
    assert Task.await(task) == :finished
    assert {:ok, nil} = RedisStore.get_lease("job-data-start:#{id}")
  end
end
