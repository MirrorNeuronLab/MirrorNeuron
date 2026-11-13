defmodule MirrorNeuron.Runtime.LocalRecovery.EligibilityTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.LocalRecovery.Eligibility

  test "failed user work stays terminal while interrupted runner ownership is recoverable" do
    refute Eligibility.recoverable_job_status?(%{
             "status" => "failed",
             "result" => %{"error" => "user failure"}
           })

    assert Eligibility.recoverable_job_status?(%{
             "status" => "failed",
             "recovery_hint" => "runner_interruption"
           })

    assert Eligibility.recoverable_job_status?(%{
             "status" => "failed",
             "result" => %{
               "agent_id" => "job_runner",
               "error" => "job coordinator exited before terminal state"
             }
           })

    refute Eligibility.recoverable_job_status?(%{"status" => "cancelled"})
  end

  test "every durable review marker prevents automatic recovery" do
    for marker <- [
          %{"recovery_status" => "paused_for_review"},
          %{"recovery" => %{"status" => "paused_for_review"}},
          %{"recovery_requires_review" => true}
        ] do
      assert Eligibility.paused_for_review?(marker)
    end

    refute Eligibility.paused_for_review?(%{})
  end

  test "only a recognized runner interruption clears the prior terminal result" do
    job = %{
      "status" => "failed",
      "result" => %{
        "agent_id" => "job_runner",
        "error" => "job coordinator exited before terminal state"
      }
    }

    assert Eligibility.auto_resume_mark_options(job)[:clear_result?]
    refute Eligibility.auto_resume_mark_options(%{"status" => "paused"})[:clear_result?]
  end
end
