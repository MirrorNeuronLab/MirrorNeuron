defmodule MirrorNeuron.Runtime.RetryArtifactsTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.{Manifest, Runtime.RetryArtifacts}

  setup do
    previous = System.get_env("MN_SHARED_STORAGE_ROOT")
    root = Path.join(System.tmp_dir!(), "retry-artifacts-#{System.unique_integer([:positive])}")
    submission = Path.join([root, "submissions", "sample"])
    run = Path.join([submission, "outputs", "runs", "run"])
    commit = Path.join([run, ".handoff", "commits", "sample"])
    evidence = Path.join([commit, "outputs", "evidence.json"])
    File.mkdir_p!(Path.dirname(evidence))
    File.write!(evidence, "saved")
    System.put_env("MN_SHARED_STORAGE_ROOT", root)
    manifest = %Manifest{metadata: %{"mn_storage" => %{"submission_path" => submission}}}

    reference = %{
      "type" => "artifact_ref",
      "version" => "mn.artifact_handoff/v1",
      "commit_id" => "sample",
      "producer" => %{
        "run_id" => "run",
        "step_instance" => "done",
        "attempt" => 1,
        "lease_epoch" => 1
      },
      "kind" => "evidence",
      "path" => "evidence.json",
      "sha256" => :crypto.hash(:sha256, "saved") |> Base.encode16(case: :lower),
      "size_bytes" => 5
    }

    File.write!(Path.join(commit, "receipt.json"), Jason.encode!(%{"references" => [reference]}))

    ledger = %{
      "run_id" => "run",
      "steps" => %{"done" => %{"output" => reference}}
    }

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_SHARED_STORAGE_ROOT", previous),
        else: System.delete_env("MN_SHARED_STORAGE_ROOT")

      File.rm_rf!(root)
    end)

    {:ok,
     job: %{"job_id" => "artifact-test", "run_id" => "run"},
     manifest: manifest,
     ledger: ledger,
     evidence: evidence}
  end

  test "captures committed handoff references and rejects changed or missing evidence", ctx do
    captured = RetryArtifacts.capture(ctx.job, ctx.ledger, ctx.manifest)
    refute Map.has_key?(captured, "error")
    assert {:ok, []} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], captured)
    File.write!(ctx.evidence, "other")
    assert {:error, _} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], captured)
    File.rm!(ctx.evidence)
    assert {:error, _} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], captured)
  end

  test "unversioned references cannot authorize retry", ctx do
    legacy = %{"kind" => "evidence", "path" => "evidence.json"}
    ledger = put_in(ctx.ledger, ["steps", "done", "output"], legacy)
    assert {:error, _} = RetryArtifacts.verify(ctx.job, ledger, ctx.manifest, [], %{})
    assert %{"error" => _} = RetryArtifacts.capture(ctx.job, ledger, ctx.manifest)
  end

  test "symlinks cannot replace committed evidence", ctx do
    File.rename!(ctx.evidence, ctx.evidence <> ".original")
    File.ln_s!(ctx.evidence <> ".original", ctx.evidence)
    assert %{"error" => _} = RetryArtifacts.capture(ctx.job, ctx.ledger, ctx.manifest)
  end
end
