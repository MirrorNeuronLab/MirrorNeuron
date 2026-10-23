defmodule MirrorNeuron.RuntimeIdTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.{JobData, JobId}

  test "run ids retain the job initials with their own compact suffix" do
    first = JobId.generate_run("job_cv-baa84224")
    second = JobId.generate_run("job_cv-baa84224")

    assert first =~ ~r/^run_cv-[a-f0-9]{8}$/
    assert second =~ ~r/^run_cv-[a-f0-9]{8}$/
    assert String.length(first) == String.length("job_cv-baa84224")
    refute first == second
    assert :ok = JobData.validate_id(first)
  end

  test "run ids use initials for operator-defined job names" do
    assert JobId.generate_run("nightly-code-review") =~ ~r/^run_ncr-[a-f0-9]{8}$/
    assert JobId.generate_run("job_la-1dd47bcc") =~ ~r/^run_la-[a-f0-9]{8}$/
    assert :ok = JobData.validate_id(JobId.generate_run(String.duplicate("a-", 63)))
  end

  test "generates compact job ids from graph initials and a fixed hash" do
    job_id = Runtime.generate_job_id("business_email_campaign_v1")

    assert job_id =~ ~r/^becv-[a-f0-9]{8}$/
    assert String.length(job_id) == 13
  end

  test "falls back to job prefix when workflow id has no alphanumeric words" do
    assert Runtime.generate_job_id("!!!") =~ ~r/^job-[a-f0-9]{8}$/
  end

  test "generated job ids are not deterministic for the same graph" do
    first = Runtime.generate_job_id("pause_resume_test")
    second = Runtime.generate_job_id("pause_resume_test")

    assert first =~ ~r/^prt-[a-f0-9]{8}$/
    assert second =~ ~r/^prt-[a-f0-9]{8}$/
    refute first == second
  end
end
