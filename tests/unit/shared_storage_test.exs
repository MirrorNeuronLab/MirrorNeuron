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

  test "terminal success copies outputs and deletes submission storage", %{root: root} do
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
    refute File.exists?(submission)
  end

  test "terminal cancel removes submission storage when outputs are missing", %{root: root} do
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
    refute File.exists?(submission)
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
