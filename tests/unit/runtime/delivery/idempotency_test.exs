defmodule MirrorNeuron.Runtime.IdempotencyTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.Idempotency

  @table :mirror_neuron_idempotency_v1

  setup do
    :ets.delete_all_objects(@table)
    on_exit(fn -> :ets.delete_all_objects(@table) end)
  end

  test "keyed results survive the request process that created them" do
    parent = self()

    first =
      Task.async(fn ->
        Idempotency.run("schedule:job-1", "request-1", %{delay_ms: 60_000}, fn ->
          send(parent, :operation_ran)
          {:ok, %{schedule_id: "schedule-1"}}
        end)
      end)
      |> Task.await()

    assert first == {:ok, %{schedule_id: "schedule-1"}}
    assert_receive :operation_ran
    assert :ets.info(@table, :owner) == Process.whereis(Idempotency)

    replayed =
      Task.async(fn ->
        Idempotency.run("schedule:job-1", "request-1", %{delay_ms: 60_000}, fn ->
          send(parent, :operation_ran_again)
          {:ok, %{schedule_id: "schedule-2"}}
        end)
      end)
      |> Task.await()

    assert replayed == first
    refute_receive :operation_ran_again
  end

  test "reusing a key with a different payload remains a conflict" do
    assert {:ok, :created} =
             Idempotency.run("create-job", "request-2", %{job_id: "job-1"}, fn ->
               {:ok, :created}
             end)

    assert {:error, :idempotency_key_reused} =
             Idempotency.run("create-job", "request-2", %{job_id: "job-2"}, fn ->
               {:ok, :duplicate}
             end)
  end
end
