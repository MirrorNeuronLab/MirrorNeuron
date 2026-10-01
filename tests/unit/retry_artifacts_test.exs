defmodule MirrorNeuron.Runtime.RetryArtifactsTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.{Manifest, Runtime.RetryArtifacts}

  setup do
    previous = System.get_env("MN_SHARED_STORAGE_ROOT")
    root = Path.join(System.tmp_dir!(), "retry-artifacts-#{System.unique_integer([:positive])}")
    submission = Path.join([root, "submissions", "sample"])
    run = Path.join([submission, "outputs", "runs", "run"])
    File.mkdir_p!(run)
    File.write!(Path.join(run, "evidence.json"), "saved")
    System.put_env("MN_SHARED_STORAGE_ROOT", root)
    manifest = %Manifest{metadata: %{"mn_storage" => %{"submission_path" => submission}}}

    ledger = %{
      "run_id" => "run",
      "steps" => %{"done" => %{"output" => %{"kind" => "evidence", "path" => "evidence.json"}}}
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
     run: run}
  end

  test "captures unhashed references and rejects changed or missing evidence", ctx do
    captured = RetryArtifacts.capture(ctx.job, ctx.ledger, ctx.manifest)
    assert [%{"size_bytes" => 5}] = captured["inventory"]
    assert {:ok, []} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], captured)
    File.write!(Path.join(ctx.run, "evidence.json"), "other")
    assert {:error, _} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], captured)
    File.rm!(Path.join(ctx.run, "evidence.json"))
    assert {:error, _} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], captured)
  end

  test "legacy references without integrity data and symlinks cannot authorize retry", ctx do
    assert {:error, _} = RetryArtifacts.verify(ctx.job, ctx.ledger, ctx.manifest, [], %{})
    File.ln_s!("evidence.json", Path.join(ctx.run, "link.json"))
    ledger = put_in(ctx.ledger, ["steps", "done", "output", "path"], "link.json")
    assert %{"error" => _} = RetryArtifacts.capture(ctx.job, ledger, ctx.manifest)
  end
end
