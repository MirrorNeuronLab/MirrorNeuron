defmodule MirrorNeuron.Runtime.RunRetry.SafetyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.RunRetry.Safety

  defp ledger(parent_status) do
    %{
      "step_order" => ["parent", "child"],
      "steps" => %{
        "parent" => %{"id" => "parent", "status" => parent_status, "instance_input" => %{}},
        "child" => %{"id" => "child", "status" => "pending", "attempt_count" => 0}
      },
      "edges" => [%{"from" => "parent", "to" => "child"}]
    }
  end

  test "unstarted children can wait for unfinished parents without inventing saved input" do
    assert :ok = Safety.verify_boundaries(ledger("failed"))

    assert {:error, reason} = Safety.verify_boundaries(ledger("completed"))
    assert reason =~ "child"

    assert :ok =
             ledger("completed")
             |> put_in(["steps", "child", "instance_input"], %{"retained" => true})
             |> Safety.verify_boundaries()
  end

  test "retries cannot discard work already completed in the authoritative run" do
    job = %{"workflow_state" => %{"steps" => %{"parent" => %{"status" => "completed"}}}}
    assert :ok = Safety.completed_work_matches(job, ledger("completed"))
    assert {:error, _} = Safety.completed_work_matches(job, ledger("failed"))
  end

  test "failed artifact retention anywhere in a checkpoint prevents replay" do
    assert {:error, _} =
             Safety.verify_references(%{"steps" => [%{"output_ref_error" => "missing"}]})

    assert :ok = Safety.verify_references(%{"steps" => [%{"output" => %{}}]})
  end
end
