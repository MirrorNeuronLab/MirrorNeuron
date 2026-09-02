defmodule MirrorNeuron.ArtifactsTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Artifacts.{BlobRef, BlobStore, JobStore, Registry, Resolver}

  setup do
    old_blob_root = System.get_env("MN_BLOB_STORE_ROOT")
    old_job_root = System.get_env("MN_JOB_ARTIFACT_ROOT")

    root =
      Path.join(System.tmp_dir!(), "mn_blob_store_test_#{System.unique_integer([:positive])}")

    blob_root = Path.join(root, "blobs")
    job_root = Path.join(root, "jobs")

    System.put_env("MN_BLOB_STORE_ROOT", blob_root)
    System.put_env("MN_JOB_ARTIFACT_ROOT", job_root)

    on_exit(fn ->
      restore_env("MN_BLOB_STORE_ROOT", old_blob_root)
      restore_env("MN_JOB_ARTIFACT_ROOT", old_job_root)
      File.rm_rf(root)
    end)

    %{root: root, blob_root: blob_root, job_root: job_root}
  end

  test "collects and normalizes blob refs from nested manifests" do
    manifest = %{
      "metadata" => %{
        "mn_artifacts" => %{
          "blob_refs" => [
            %{
              "type" => "blob_ref",
              "sha256" => String.duplicate("A", 64),
              "size_bytes" => "42",
              "payload_path" => "\\videos\\demo.mp4"
            }
          ]
        }
      }
    }

    assert [
             %{
               "sha256" => sha,
               "size_bytes" => 42,
               "payload_path" => "videos/demo.mp4"
             }
           ] = BlobRef.collect(manifest)

    assert sha == String.duplicate("a", 64)
  end

  test "materializes payload refs from the shared blob store through a job folder", %{
    root: root,
    job_root: job_root
  } do
    source = Path.join(root, "source.txt")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "large doc")

    assert {:ok, %{sha256: sha256}} = BlobStore.put_file(source)

    refs = [
      %{
        "type" => "blob_ref",
        "sha256" => sha256,
        "size_bytes" => 9,
        "payload_path" => "docs/input.txt"
      }
    ]

    target = Path.join(root, "stage/docs")

    assert :ok = Resolver.materialize_payload_refs(refs, "docs", target, job_id: "job-artifacts")
    assert File.read!(Path.join(target, "input.txt")) == "large doc"

    assert File.read!(Path.join([job_root, "job-artifacts", "payloads", "input.txt"])) ==
             "large doc"
  end

  test "materializes the payload root when an upload uses dot", %{root: root} do
    assert {:ok, %{sha256: first_sha}} = BlobStore.put_bytes("first")
    assert {:ok, %{sha256: second_sha}} = BlobStore.put_bytes("second")

    refs = [
      %{
        "type" => "blob_ref",
        "sha256" => first_sha,
        "payload_path" => "services/cctv_web_ui.py"
      },
      %{
        "type" => "blob_ref",
        "sha256" => second_sha,
        "payload_path" => "domain/report.py"
      }
    ]

    target = Path.join(root, "stage/root")

    assert :ok = Resolver.materialize_payload_refs(refs, ".", target)
    assert File.read!(Path.join(target, "services/cctv_web_ui.py")) == "first"
    assert File.read!(Path.join(target, "domain/report.py")) == "second"
  end

  test "resolver fails fast when a shared blob is missing" do
    sha256 = String.duplicate("a", 64)

    assert {:error, reason} =
             Resolver.resolve_ref(%{"type" => "blob_ref", "sha256" => sha256})

    assert reason =~ "missing from shared blob store"
  end

  test "resolver rejects payload paths that escape the target", %{root: root} do
    assert {:ok, %{sha256: sha256}} = BlobStore.put_bytes("escape")

    refs = [
      %{
        "type" => "blob_ref",
        "sha256" => sha256,
        "payload_path" => "docs/../outside.txt"
      }
    ]

    target = Path.join(root, "stage/docs")

    assert {:error, reason} = Resolver.materialize_payload_refs(refs, "docs", target)
    assert reason =~ "unsafe artifact path"
    refute File.exists?(Path.join(root, "stage/outside.txt"))
  end

  test "registry advertises shared filesystem locations without urls" do
    assert {:ok, %{sha256: sha256}} = BlobStore.put_bytes("shared")

    ref = %{
      "type" => "blob_ref",
      "sha256" => sha256,
      "size_bytes" => 6,
      "media_type" => "text/plain"
    }

    assert %{
             "storage" => "shared_fs",
             "root" => "blob_store",
             "path" => path,
             "status" => "available"
           } = Registry.local_location(ref)

    assert path == Path.join(binary_part(sha256, 0, 2), sha256)
    refute Map.has_key?(Registry.local_location(ref), "url")

    assert %{"artifact_store" => %{"type" => "shared_fs_cas", "root" => "blob_store"}} =
             Registry.node_advertisement()
  end

  test "job artifact cleanup removes only the requested job folder", %{job_root: job_root} do
    assert {:ok, job_path} = JobStore.ensure_job_dir("job-one")
    assert {:ok, other_path} = JobStore.ensure_job_dir("job-two")

    File.write!(Path.join(job_path, "output.txt"), "done")
    File.write!(Path.join(other_path, "output.txt"), "keep")

    assert :ok = JobStore.cleanup_job("job-one")
    refute File.exists?(job_path)
    assert File.read!(Path.join(other_path, "output.txt")) == "keep"
    assert Path.expand(JobStore.root()) == Path.expand(job_root)
  end

  test "job artifact cleanup rejects unsafe job ids" do
    assert {:error, reason} = JobStore.job_path("../outside")
    assert reason =~ "single path segment"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
