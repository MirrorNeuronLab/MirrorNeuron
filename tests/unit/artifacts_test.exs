defmodule MirrorNeuron.ArtifactsTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Artifacts.{BlobRef, BlobStore, Resolver}

  setup do
    old_root = System.get_env("MN_BLOB_STORE_ROOT")

    root =
      Path.join(System.tmp_dir!(), "mn_blob_store_test_#{System.unique_integer([:positive])}")

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

  test "artifact HTTP server serves blobs without authorization", %{root: root} do
    old_token = System.get_env("MN_ARTIFACT_AUTH_TOKEN")
    System.put_env("MN_ARTIFACT_AUTH_TOKEN", "ignored-artifact-token")

    on_exit(fn ->
      restore_env("MN_ARTIFACT_AUTH_TOKEN", old_token)
    end)

    assert {:ok, %{sha256: sha256}} = BlobStore.put_bytes("remote doc")

    port = free_tcp_port()
    name = :"artifact_http_#{System.unique_integer([:positive])}"

    start_supervised!(
      {MirrorNeuron.Artifacts.HttpServer,
       [enabled: true, port: port, bind_host: "127.0.0.1", name: name]}
    )

    :inets.start()

    request = {String.to_charlist("http://127.0.0.1:#{port}/blobs/#{sha256}"), []}

    assert {:ok, {{_version, 200, _reason}, _headers, body}} =
             :httpc.request(:get, request, [], body_format: :binary)

    assert body == "remote doc"
    assert File.regular?(Path.join([root, binary_part(sha256, 0, 2), sha256]))
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
