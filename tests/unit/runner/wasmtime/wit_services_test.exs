defmodule MirrorNeuron.Runner.WitServicesTest do
  use MirrorNeuron.RedisStoreCase, async: false
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.Interactions
  alias MirrorNeuron.Sandbox.{WasmtimePayload, WitArtifacts, WitBroker, WitServices}

  setup do
    root = Path.join(System.tmp_dir!(), "wit-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "submissions/sub"))
    old = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", root)

    on_exit(fn ->
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old)
      File.rm_rf!(root)
    end)

    record = %{
      "status" => "running",
      "job_id" => "execution",
      "stable_job_id" => "definition",
      "workflow_run_id" => "workflow",
      "manifest" => %{
        "metadata" => %{
          "mn_storage" => %{"submission_id" => "sub", "output_copy" => [%{"layout" => "batch"}]}
        }
      }
    }

    assert {:ok, _} = RedisStore.persist_job("execution", record)
    {:ok, root: root, record: record}
  end

  defp call(key, args), do: WitServices.call("execution", "workflow", key, args, %{})

  test "copies only hash-verified inputs for this physical run", %{root: root, record: record} do
    prefix = "runtime/mn_local_inputs"
    base = prefix <> "/software_sources"
    input = Path.join([root, "submissions/sub/inputs", base])
    File.mkdir_p!(input)
    File.write!(Path.join(input, "spec.txt"), "spec")
    File.write!(Path.join(input, "unlisted.txt"), "other")

    inventory = [
      %{
        "payload_path" => base,
        "files" => [
          %{
            "relative_path" => "spec.txt",
            "size_bytes" => 4,
            "sha256" => WitArtifacts.digest("spec")
          }
        ]
      }
    ]

    record =
      put_in(record, ["manifest", "metadata", "mn_local_inputs"], %{"folders" => inventory})

    assert {:ok, _} = RedisStore.persist_job("execution", record)
    opts = [job_id: "execution"]
    target = Path.join(root, "guest")
    assert :ok = WasmtimePayload.stage_run_inputs(prefix, target, "workflow", opts)
    assert File.ls!(Path.join(target, "software_sources")) == ["spec.txt"]

    assert {:error, :run_scope_unavailable} =
             WasmtimePayload.stage_run_inputs(prefix, target, "other", opts)

    File.write!(Path.join(input, "spec.txt"), "oops")

    assert {:error, :staged_input_integrity_error} =
             WasmtimePayload.stage_run_inputs(prefix, target <> "-retry", "workflow", opts)
  end

  test "commits and publishes verified run files through Core", %{root: root, record: record} do
    data = "<html>Run</html>"
    path = "web/report name.html"
    assert {:ok, ref} = call("artifacts.commit", [path, "html", data])
    assert {:ok, ^ref} = call("artifacts.commit", [path, "html", data])
    assert {:error, :artifact_conflict} = call("artifacts.commit", [path, "html", "changed"])
    assert {:ok, ^data} = call("artifacts.read", [path, ref["sha256"]])
    assert {:error, _} = call("artifacts.read", [path, WitArtifacts.digest("other")])
    assert {:error, _} = call("artifacts.commit", ["../x", "source", "private"])

    assert {:ok, _} =
             call("artifacts.commit", ["source/.github/workflows/ci.yml", "source", "name: check"])

    assert {:ok, handle} = call("artifacts.static-report", [path, ref["sha256"], "Verification"])
    assert handle["url"] =~ "report%20name.html"
    assert handle["metadata"]["sha256"] == ref["sha256"]
    assert {:ok, []} = call("artifacts.publish", [Jason.encode!(%{path => ref})])
    assert File.read!(Path.join([root, "submissions/sub/outputs/user", path])) == data
    assert {:error, _} = call("artifacts.publish", [Jason.encode!(%{"elsewhere" => ref})])

    assert {:error, :run_scope_unavailable} =
             WitServices.call("execution", "other", "artifacts.read", [path, nil], %{})

    assert {:ok, _} = RedisStore.persist_job("execution", %{record | "status" => "completed"})
    assert {:error, :run_scope_unavailable} = call("artifacts.read", [path, nil])
  end

  test "Core owns approval revisions and the socket enforces a per-step grant" do
    req = %{
      "request_id" => "rules-1",
      "prompt" => "Review rules",
      "expires_at" => System.system_time(:millisecond) + 600_000,
      "review_revision" => 1
    }

    assert {:ok, %{"state" => "pending"} = record} =
             call("approvals.request", [Jason.encode!(req)])

    assert {:ok, ^record} = call("approvals.request", [Jason.encode!(req)])

    assert {:error, :approval_revision_mismatch} =
             call("approvals.request", [Jason.encode!(%{req | "review_revision" => 2})])

    assert {:error, _} = call("approvals.respond", [record["id"], "approve"])

    assert {:ok, _} =
             Interactions.command(%{
               "op" => "respond",
               "id" => record["id"],
               "expected_revision" => 1,
               "command_id" => "human-choice",
               "answer" => %{"option_id" => "approve"}
             })

    assert {:ok, %{"receipt" => %{"answer" => %{"option_id" => "approve"}}}} =
             call("approvals.status", ["rules-1"])

    assert :ok ==
             WitBroker.with_socket(["approvals.status"], &call/2, fn socket ->
               {:ok, peer} =
                 :gen_tcp.connect({:local, to_charlist(socket)}, 0, [
                   :binary,
                   active: false,
                   packet: 4
                 ])

               request = fn service, op, args ->
                 :ok =
                   :gen_tcp.send(
                     peer,
                     Jason.encode!(%{"service" => service, "operation" => op, "args" => args})
                   )

                 {:ok, reply} = :gen_tcp.recv(peer, 0, 5000)
                 Jason.decode!(reply)
               end

               assert %{"error" => "Capability denied"} =
                        request.("artifacts", "read", ["some.json", nil])

               assert %{"ok" => received} = request.("approvals", "status", ["rules-1"])
               assert Jason.decode!(received)["id"] == record["id"]
               :gen_tcp.close(peer)
             end)
  end
end
