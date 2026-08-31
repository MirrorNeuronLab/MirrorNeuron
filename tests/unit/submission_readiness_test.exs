defmodule MirrorNeuron.Artifacts.SubmissionReadinessTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Artifacts.SubmissionReadiness

  setup do
    root = Path.join(System.tmp_dir!(), "mn-readiness-#{System.unique_integer([:positive])}")
    previous = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", previous),
        else: System.delete_env("MN_RUNTIME_SHARED_STORAGE_ROOT")

      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "waits for absent, incomplete, and corrupt remote snapshots before accepting a complete tree",
       %{
         root: root
       } do
    submission_root = Path.join([root, "submissions", "submission-readiness-test"])
    inputs_root = Path.join(submission_root, "inputs")
    input_path = Path.join([inputs_root, "mn_local_inputs", "source", "main.py"])
    contents = "print('ready')\n"
    marker = marker_for("mn_local_inputs/source/main.py", contents)
    marker_path = Path.join(inputs_root, ".mn-inputs-ready.json")
    descriptor = descriptor_for(marker)
    manifest = manifest_for(submission_root, descriptor)

    assert {:waiting, waiting} = SubmissionReadiness.verify(manifest)
    assert waiting["reason"] == "readiness_manifest_missing"
    assert waiting["remaining_files"] == 1

    File.mkdir_p!(inputs_root)
    File.write!(marker_path, marker)

    assert {:waiting, waiting} = SubmissionReadiness.verify(manifest)
    assert waiting["remaining_files"] == 1
    assert waiting["remaining_bytes"] == byte_size(contents)

    File.mkdir_p!(Path.dirname(input_path))
    File.write!(input_path, "partial")
    assert {:waiting, _waiting} = SubmissionReadiness.verify(manifest)

    File.write!(input_path, contents)
    assert {:ready, ready} = SubmissionReadiness.verify(manifest)
    assert ready["remaining_files"] == 0
    assert ready["total_files"] == 1

    File.write!(marker_path, "corrupt")
    assert {:waiting, waiting} = SubmissionReadiness.verify(manifest)
    assert waiting["reason"] == "readiness_manifest_size_mismatch"
  end

  test "rejects unsafe inventory paths without reading outside the shared submission", %{
    root: root
  } do
    submission_root = Path.join([root, "submissions", "submission-readiness-unsafe"])
    inputs_root = Path.join(submission_root, "inputs")
    marker_path = Path.join(inputs_root, ".mn-inputs-ready.json")
    marker = marker_for("../outside", "not used")
    descriptor = descriptor_for(marker)

    File.mkdir_p!(inputs_root)
    File.write!(marker_path, marker)

    assert {:error, "invalid_submission_readiness_entry", _metrics} =
             SubmissionReadiness.verify(manifest_for(submission_root, descriptor))
  end

  defp manifest_for(submission_root, descriptor) do
    %{
      "metadata" => %{
        "mn_storage" => %{
          "submission_id" => Path.basename(submission_root),
          "submission_path" => submission_root,
          "inputs" => %{"readiness" => descriptor}
        }
      }
    }
  end

  defp marker_for(path, contents) do
    Jason.encode!(%{
      "version" => "mn.input_readiness/v1",
      "files" => [
        %{
          "path" => path,
          "size_bytes" => byte_size(contents),
          "sha256" => sha256(contents)
        }
      ],
      "file_count" => 1,
      "total_bytes" => byte_size(contents)
    })
  end

  defp descriptor_for(marker) do
    %{
      "version" => "mn.input_readiness/v1",
      "path" => "inputs/.mn-inputs-ready.json",
      "sha256" => sha256(marker),
      "size_bytes" => byte_size(marker),
      "file_count" => 1,
      "total_bytes" => byte_size("print('ready')\n")
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
