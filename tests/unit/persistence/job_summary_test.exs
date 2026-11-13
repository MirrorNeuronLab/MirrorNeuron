defmodule MirrorNeuron.Persistence.JobSummaryTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Persistence.JobSummary

  test "compact summaries retain the persisted field set and defaults" do
    empty_fields = ~w(graph_id job_name status admission running_time clock_session
      attempt_started_at restart_reason recovery_mode job_type submitted_at updated_at
      placement_policy scheduler lease_owner requested_recovery_policy recovery_policy
      reliability restart_policy reschedule_policy policy_state recovery_status
      recovery_reason recovery_hint last_event failure manifest_ref result_ref
      workflow_state_ref workflow_state)

    expected =
      empty_fields
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "job_id" => "fallback",
        "attempt" => 0,
        "recovery_requires_review" => false,
        "executor_count" => 0,
        "active_executors" => 0,
        "nodes" => [],
        "sandbox_names" => []
      })

    assert JobSummary.build("fallback", %{}) == expected
    assert Jason.decode!(Jason.encode!(expected)) == expected
  end

  test "mixed key precedence, lease owner and ordered scheduler nodes remain stable" do
    job = %{
      :job_id => "atom-id",
      "job_id" => "string-id",
      :attempt => 3,
      "attempt" => nil,
      :lease => %{owner_id: "owner"},
      :scheduler => %{
        status: "placed",
        placements: [%{node: "z"}, %{"node" => "a"}, %{node: "z"}, %{}]
      }
    }

    summary = JobSummary.build("fallback", job)
    assert summary["job_id"] == "string-id"
    assert summary["attempt"] == nil
    assert summary["lease_owner"] == "owner"
    assert summary["scheduler"]["placement_count"] == 4
    assert summary["scheduler"]["nodes"] == ["a", "z"]
  end

  test "terminal failure and interruption hints preserve their distinct contracts" do
    job = %{
      status: "failed",
      result: %{agent_id: "job_runner", error: "job coordinator exited before terminal state"}
    }

    summary = JobSummary.build("job", job)
    assert summary["recovery_hint"] == "runner_interruption"

    assert summary["failure"] == %{
             "message" => "job coordinator exited before terminal state",
             "agent_id" => "job_runner"
           }

    refute JobSummary.build("job", %{job | status: "running"})["failure"]
    structured = %{job | result: %{error: %{description: "failed", retryable: false}}}

    assert JobSummary.build("job", structured)["failure"] == %{
             "message" => "failed",
             "retryable" => false
           }
  end

  test "workflow summaries omit heavy step state while preserving dynamic topology" do
    state = %{
      "graph_revision" => 3,
      "edges" => [%{"from" => "a", "to" => "b"}],
      "dynamic_history" => [%{"revision" => 3}],
      "private_state" => "omit",
      "steps" => %{
        "a" => %{
          "id" => "a",
          "status" => "completed",
          "output_ref" => %{"id" => "blob"},
          "output" => "omit"
        },
        "b" => nil
      }
    }

    expected =
      state
      |> Map.delete("private_state")
      |> put_in(["steps", "a"], Map.delete(state["steps"]["a"], "output"))
      |> put_in(["steps", "b"], %{"status" => "unknown"})

    assert JobSummary.build("job", %{workflow_state: state})["workflow_state"] == expected
    assert JobSummary.build("job", %{workflow_state: %{steps: %{}}})["workflow_state"] == nil
  end
end
