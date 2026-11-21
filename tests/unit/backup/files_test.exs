defmodule MirrorNeuron.Backup.FilesTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Backup.Files
  alias Mirrorneuron.Job.V1.JobBackupChunk

  setup do
    root = Path.join(System.tmp_dir!(), "mn-backup-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "round trips bounded chunks, empty directories, executable modes and hashes", %{root: root} do
    source = Path.join(root, "source")
    File.mkdir_p!(Path.join(source, "empty"))
    File.write!(Path.join(source, "script"), String.duplicate("a", 1_048_577))
    File.chmod!(Path.join(source, "script"), 0o700)
    entries = Files.tree(source, "bundle")
    chunks = Enum.to_list(Files.chunks(entries))
    assert Enum.all?(chunks, &(byte_size(&1.data) <= 1_048_576))
    target = Path.join(root, "target")
    File.mkdir_p!(target)
    assert :ok = Files.receive!(chunks, target)
    assert :ok = Files.verify!(target, Files.inventory(entries))
    assert File.dir?(Path.join(target, "bundle/empty"))
    File.write!(Path.join(target, "bundle/script"), "corrupt")

    assert_raise ArgumentError, ~r/checksum/, fn ->
      Files.verify!(target, Files.inventory(entries))
    end
  end

  test "rejects traversal, symlinks, duplicate paths, and incomplete streams", %{root: root} do
    for name <- ["../x", "/x", "C:/x", "a\\x", "a//x", "a/./x"] do
      assert_raise ArgumentError, fn -> Files.safe_path!(root, name) end
    end

    File.ln_s!(root, Path.join(root, "link"))
    assert_raise ArgumentError, fn -> Files.tree(root, "bundle") end
    target = Path.join(root, "target")
    File.mkdir_p!(target)

    assert_raise ArgumentError, ~r/incomplete/, fn ->
      Files.receive!([%JobBackupChunk{path: "x", data: "a", version: 1}], target)
    end

    assert_raise ArgumentError, ~r/duplicate/, fn ->
      Files.receive!(
        [
          %JobBackupChunk{path: "A", eof: true, version: 1},
          %JobBackupChunk{path: "a", eof: true, version: 1}
        ],
        target
      )
    end
  end

  test "backup commands require identity and deny network-only mode" do
    for command <- [:ExportJobBackup, :RestoreJobBackup] do
      assert MirrorNeuron.Grpc.CommandPolicy.policies(:job, command) == %{
               network_only_denied: true,
               identity_auth_required: true,
               network_join_auth_required: false
             }
    end
  end
end
