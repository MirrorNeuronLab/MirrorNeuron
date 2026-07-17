defmodule MirrorNeuron.Artifacts.StagedArtifactTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Artifacts.StagedArtifact.{IntegrityError, NotReadyError}

  setup do
    root =
      Path.join(System.tmp_dir!(), "mn-staged-artifact-#{System.unique_integer([:positive])}")

    previous = System.get_env("MN_SHARED_STORAGE_ROOT")
    System.put_env("MN_SHARED_STORAGE_ROOT", root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env("MN_SHARED_STORAGE_ROOT", previous)
    end)

    %{root: root, submission: Path.join([root, "submissions", "submission-1"])}
  end

  test "stages and resolves a content-addressed JSON value", %{submission: submission} do
    assert {:ok, reference} =
             StagedArtifact.stage(%{"records" => ["one"]},
               kind: "step_output",
               run_id: "run-1",
               submission_id: "submission-1",
               submission_path: submission
             )

    assert reference["version"] == "mn.staged_artifact/v1"
    assert reference["storage"] == "syncthing"
    assert reference["submission_id"] == "submission-1"
    assert File.regular?(Path.join(submission, reference["relative_path"]))
    assert StagedArtifact.resolve!(reference, timeout_ms: 0) == %{"records" => ["one"]}
  end

  test "waits for a synchronized file and rejects corrupt content", %{submission: submission} do
    assert {:ok, reference} =
             StagedArtifact.stage(%{"value" => "ready"},
               run_id: "run-1",
               submission_id: "submission-1",
               submission_path: submission
             )

    target = Path.join(submission, reference["relative_path"])
    delayed = target <> ".delayed"
    File.rename!(target, delayed)

    Task.start(fn ->
      Process.sleep(50)
      File.rename!(delayed, target)
    end)

    assert StagedArtifact.resolve!(reference, timeout_ms: 500) == %{"value" => "ready"}

    File.write!(target, "{}")

    assert_raise IntegrityError, ~r/size mismatch/, fn ->
      StagedArtifact.resolve!(reference, timeout_ms: 0)
    end
  end

  test "raises a retryable not-ready error after the bounded wait", %{submission: submission} do
    reference = %{
      "type" => "artifact_ref",
      "version" => "mn.staged_artifact/v1",
      "storage" => "syncthing",
      "kind" => "step_output",
      "submission_id" => "submission-1",
      "run_id" => "run-1",
      "relative_path" => "outputs/runs/run-1/artifacts/aa/missing.json",
      "size_bytes" => 2,
      "sha256" => String.duplicate("a", 64)
    }

    assert_raise NotReadyError, ~r/artifact_not_ready/, fn ->
      StagedArtifact.resolve!(reference, submission_path: submission, timeout_ms: 0)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
