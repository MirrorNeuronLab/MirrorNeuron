defmodule MirrorNeuron.Monitor.ProjectionTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Monitor.{Compaction, Jobs}

  test "compact multibyte diagnostics remain valid JSON" do
    value = String.duplicate("界", 3000)
    compacted = Compaction.compact_value(%{"message" => value})
    assert String.valid?(compacted["message"])
    assert {:ok, _} = Jason.encode(compacted)
    assert compacted["message"] =~ "truncated"
    assert byte_size(compacted["message"]) < byte_size(value)
  end

  test "live filtering precedes the basic summary limit" do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    jobs = [
      %{"job_id" => "terminal", "status" => "completed", "updated_at" => now},
      %{"job_id" => "live", "status" => "running", "updated_at" => now}
    ]

    assert [%{"job_id" => "live"}] =
             Jobs.summarize_jobs(jobs, summary: :basic, live_only: true, limit: 1)
  end

  test "compaction retains staged references and removes embedded outputs" do
    ref = %{"version" => "mn.staged_artifact/v1", "path" => "outputs/result.json"}

    job = %{
      "manifest" => %{"private" => true},
      "result" => %{"large" => true},
      "workflow_state" => %{
        "messages" => ["secret"],
        "steps" => %{
          "one" => %{"status" => "completed", "output" => ref, "last_message" => "secret"}
        }
      }
    }

    compacted = Compaction.public_job(job, compact: true)
    refute Map.has_key?(compacted, "manifest")
    refute Map.has_key?(compacted, "result")

    assert compacted["workflow_state"]["steps"]["one"] == %{
             "status" => "completed",
             "output_ref" => ref
           }
  end

  test "bounded details preserve small results and reduce large workflow snapshots" do
    small = %{"job" => %{"job_id" => "job"}, "summary" => %{"status" => "running"}}
    assert MirrorNeuron.Monitor.bound_job_details(small) == small

    large =
      put_in(small, ["job", "workflow_state"], %{
        "steps" => Map.new(1..500, &{to_string(&1), %{"status" => "running"}})
      })

    bounded = MirrorNeuron.Monitor.bound_job_details(large, 2000)
    assert bounded["job"]["workflow_step_count"] == 500
    assert bounded["summary"]["detail_truncated"]
    assert byte_size(Jason.encode!(bounded)) <= 2000
  end
end
