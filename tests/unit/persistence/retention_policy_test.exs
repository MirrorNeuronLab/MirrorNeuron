defmodule MirrorNeuron.Persistence.RedisStore.RetentionPolicyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy

  test "failed runs retain retry state until explicitly discarded" do
    for job <- [%{"status" => "failed"}, %{status: "failed"}] do
      assert RetentionPolicy.retained_retry_state?(job)
    end

    refute RetentionPolicy.retained_retry_state?(%{
             "status" => "failed",
             "retry_checkpoint_discarded" => true
           })
  end

  test "retry receipts protect a completed run but an empty receipt map does not" do
    job = %{"status" => "completed", "retry_receipts" => %{"request" => %{"run_id" => "retry"}}}
    assert RetentionPolicy.retained_retry_state?(job)
    refute RetentionPolicy.retained_retry_state?(Map.put(job, "retry_receipts", %{}))
    refute RetentionPolicy.retained_retry_state?(Map.put(job, "retry_checkpoint_discarded", true))
  end

  test "elapsed retention never deletes active or retained retry state" do
    for status <- ["running", "paused", "failed"] do
      refute RetentionPolicy.terminal_job_expired?(
               %{"status" => status, "updated_at" => "2000-01-01T00:00:00Z"},
               0
             )
    end
  end

  test "disabled retention and invalid timestamps do not expire terminal state" do
    job = %{"status" => "completed", "updated_at" => "2000-01-01T00:00:00Z"}
    assert RetentionPolicy.terminal_job_expired?(job, 60)
    refute RetentionPolicy.terminal_job_expired?(job, -1)
    refute RetentionPolicy.terminal_job_expired?(Map.put(job, "updated_at", "invalid"), 60)
  end
end
