defmodule MirrorNeuron.Artifacts.SharedStorageTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Artifacts.SharedStorage

  setup do
    old_shared = System.get_env("MN_SHARED_STORAGE_ROOT")
    old_runtime = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")

    root =
      Path.join(System.tmp_dir!(), "mn_shared_storage_test_#{System.unique_integer([:positive])}")

    System.put_env("MN_SHARED_STORAGE_ROOT", root)
    System.delete_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    File.mkdir_p!(root)

    on_exit(fn ->
      restore_env("MN_SHARED_STORAGE_ROOT", old_shared)
      restore_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_runtime)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "terminal success copies outputs and retains submission storage", %{root: root} do
    submission = Path.join([root, "submissions", "sub-1"])
    source = Path.join([submission, "outputs", "user"])
    target = Path.join(root, "target")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "report.txt"), "done")

    assert {:ok, []} =
             SharedStorage.finalize_terminal_job(
               "job-1",
               manifest(submission, source, target),
               "completed"
             )

    assert File.read!(Path.join(target, "report.txt")) == "done"
    assert File.exists?(submission)
  end

  test "master host output copy leaves shared submission for launcher", %{root: root} do
    submission = Path.join([root, "submissions", "sub-master-host"])
    source = Path.join([submission, "outputs", "user"])
    target = Path.join(root, "target-master-host")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "report.txt"), "done")

    manifest =
      manifest(submission, source, target)
      |> put_in(["metadata", "mn_storage", "output_copy_executor"], "master_host")

    assert {:ok, []} =
             SharedStorage.finalize_terminal_job(
               "job-master-host",
               manifest,
               "completed"
             )

    assert File.read!(Path.join(source, "report.txt")) == "done"
    refute File.exists?(target)
    assert File.exists?(submission)
  end

  test "terminal run publishes a complete shared output receipt", %{root: root} do
    submission = Path.join([root, "submissions", "sub-receipt"])
    run_dir = Path.join([submission, "outputs", "runs", "run-1"])
    nested = Path.join(run_dir, "case")
    user_dir = Path.join([submission, "outputs", "user"])
    File.mkdir_p!(nested)
    File.mkdir_p!(user_dir)
    File.write!(Path.join(run_dir, "final_report.md"), "draft")
    File.write!(Path.join(run_dir, "result.json"), "{\"product\":true}")
    File.write!(Path.join(nested, "evidence.json"), "{}")
    File.write!(Path.join(user_dir, "review_index.json"), "{}")
    File.write!(Path.join(run_dir, ".mn_completion.json.tmp"), "stale")

    assert :ok =
             SharedStorage.publish_run_completion(
               manifest(submission, run_dir, Path.join(root, "target"))
               |> put_in(["metadata", "mn_storage", "output_copy_executor"], "master_host"),
               "run-1",
               "completed"
             )

    receipt = Jason.decode!(File.read!(Path.join(run_dir, ".mn_completion.json")))
    assert File.read!(Path.join(run_dir, "result.json")) == "{\"product\":true}"
    assert receipt["status"] == "completed"
    assert receipt["run_id"] == "run-1"

    assert Enum.map(receipt["output_files"], & &1["path"]) ==
             Enum.sort([
               Path.join(nested, "evidence.json"),
               Path.join(run_dir, "final_report.md"),
               Path.join(run_dir, "result.json"),
               Path.join(user_dir, "review_index.json")
             ])

    assert {:error, :invalid_run_output_path} =
             SharedStorage.publish_run_completion(
               manifest(submission, run_dir, Path.join(root, "target"))
               |> put_in(["metadata", "mn_storage", "output_copy_executor"], "master_host"),
               "../unsafe",
               "completed"
             )
  end

  test "terminal cancel retains submission storage when outputs are missing", %{root: root} do
    submission = Path.join([root, "submissions", "sub-cancel"])
    source = Path.join([submission, "outputs", "user"])
    target = Path.join(root, "target-cancel")
    File.mkdir_p!(submission)

    assert {:ok, warnings} =
             SharedStorage.finalize_terminal_job(
               "job-cancel",
               manifest(submission, source, target),
               "cancelled"
             )

    assert [%{"code" => "missing_output_source", "fatal" => false}] = warnings
    assert File.exists?(submission)
  end

  test "failed output copy returns warning and keeps submission storage", %{root: root} do
    submission = Path.join([root, "submissions", "sub-warning"])
    source = Path.join([submission, "outputs", "user"])
    target_parent = Path.join(root, "not-a-directory")
    target = Path.join(target_parent, "target")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "report.txt"), "done")
    File.write!(target_parent, "file")

    assert {:error, warnings} =
             SharedStorage.finalize_terminal_job(
               "job-warning",
               manifest(submission, source, target),
               "completed"
             )

    assert [%{"code" => "output_copy_failed", "fatal" => true}] = warnings
    assert File.exists?(submission)
  end

  test "cleanup_job removes shared submission from persisted manifest", %{root: root} do
    submission = Path.join([root, "submissions", "sub-retention"])
    source = Path.join([submission, "outputs", "user"])
    target = Path.join(root, "target-retention")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "report.txt"), "done")

    assert :ok =
             SharedStorage.cleanup_job("job-retention", %{
               "manifest" => manifest(submission, source, target)
             })

    refute File.exists?(submission)
  end

  defp manifest(submission, source, target) do
    %{
      "metadata" => %{
        "mn_storage" => %{
          "submission_path" => submission,
          "output_copy" => [
            %{
              "source_path" => source,
              "target_path" => target,
              "kind" => "directory"
            }
          ]
        }
      }
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
