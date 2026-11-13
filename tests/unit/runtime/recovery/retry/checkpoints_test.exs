defmodule MirrorNeuron.Runtime.RunRetry.CheckpointsTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.RunRetry
  alias MirrorNeuron.Runtime.RunRetry.Checkpoints

  defp job do
    %{
      "job_id" => "run-a",
      "run_id" => "run-a",
      "stable_job_id" => "job-a",
      "attempt" => 2,
      "data_generation" => 3,
      "manifest" => %{"graph_id" => "graph-a"},
      "inputs" => %{"items" => [1, 2]},
      "running_time" => %{"accumulated_ms" => 500},
      "retry_request" => %{"effective_configuration_overrides" => %{"limit" => 5}}
    }
  end

  test "checkpoint integrity rejects changes to every durable execution identity" do
    job = job()
    checkpoint = RunRetry.checkpoint(job, %{"steps" => %{}})
    assert :ok = Checkpoints.checkpoint_identity(job, checkpoint)

    for {field, value} <- [
          {"run_id", "other-run"},
          {"stable_job_id", "other-job"},
          {"attempt", 3},
          {"data_generation", 4},
          {"manifest", %{"graph_id" => "different"}},
          {"inputs", %{"items" => [2, 1]}}
        ] do
      assert {:error, _} = Checkpoints.checkpoint_identity(Map.put(job, field, value), checkpoint)
    end
  end

  test "changing retained workflow data invalidates a checkpoint even with the same run identity" do
    job = job()
    checkpoint = RunRetry.checkpoint(job, %{"steps" => %{}})
    changed = put_in(checkpoint, ["workflow", "steps", "forged"], %{"status" => "completed"})
    assert {:error, _} = Checkpoints.checkpoint_identity(job, changed)
  end

  test "canonical digests survive JSON map ordering but preserve ordered inputs" do
    first = %{"a" => %{"x" => 1, "y" => 2}, "b" => [1, 2]}
    second = Jason.decode!(~s({"b":[1,2],"a":{"y":2,"x":1}}))
    assert RunRetry.digest(first) == RunRetry.digest(second)
    refute RunRetry.digest(first) == RunRetry.digest(%{first | "b" => [2, 1]})
  end

  test "checkpoint capture retains consumed time and effective overrides" do
    checkpoint = RunRetry.checkpoint(job(), %{}, %{"step-a" => "artifact-a"})
    assert checkpoint["running_time"] == %{"accumulated_ms" => 500}
    assert checkpoint["configuration_overrides"] == %{"limit" => 5}
    assert checkpoint["artifacts"] == %{"step-a" => "artifact-a"}
  end
end
