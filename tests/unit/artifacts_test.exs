defmodule MirrorNeuron.ArtifactsTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Artifacts.{BlobRef, BlobStore, Resolver}

  setup do
    old_root = System.get_env("MN_BLOB_STORE_ROOT")
    root = Path.join(System.tmp_dir!(), "mn_blob_store_test_#{System.unique_integer([:positive])}")
    System.put_env("MN_BLOB_STORE_ROOT", root)

    on_exit(fn ->
      restore_env("MN_BLOB_STORE_ROOT", old_root)
      File.rm_rf(root)
    end)

    %{root: root}
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

  test "materializes payload refs from the local blob store", %{root: root} do
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

    assert :ok = Resolver.materialize_payload_refs(refs, "docs", target)
    assert File.read!(Path.join(target, "input.txt")) == "large doc"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
