defmodule MirrorNeuron.RuntimeIdTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime

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
