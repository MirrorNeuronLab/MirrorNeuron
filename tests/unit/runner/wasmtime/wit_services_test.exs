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

  test "RAG waits through a growing install and resumes guest supervision when the call returns",
       %{root: root, record: record} do
    key = :native_sdk_grpc_job_response_client
    client = Application.get_env(:mirror_neuron, key)
    host = System.get_env("MN_WASMTIME_HOST_BIN")
    rpc_timeout = System.get_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS")

    on_exit(fn ->
      restore_env(key, client)
      restore_system_env("MN_WASMTIME_HOST_BIN", host)
      restore_system_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS", rpc_timeout)
    end)

    System.put_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS", "95000")

    dep = %{
      "name" => "mn_sdk_workflow_context",
      "source" => "payload",
      "type" => "wit",
      "version" => "1.0.0",
      "sha256" => WitArtifacts.digest("component")
    }

    record =
      record
      |> put_in(["manifest", "skill_dependencies"], [dep])
      |> Map.put("status", "validated")

    assert {:ok, _} = RedisStore.persist_job("execution", record)

    executable = Path.join(root, "test-embedder")
    File.write!(Path.join(root, "worker.wasm"), <<0, "asm", 13, 0, 1, 0>>)

    File.write!(executable, """
    #!/usr/bin/env python3
    import json, socket, struct, sys, time
    from pathlib import Path
    with socket.socket(socket.AF_UNIX) as peer:
        peer.connect(sys.argv[3])
        payload = json.dumps({"service":"skill","operation":"workflow-context.query-knowledge","args":["{}"]}).encode()
        peer.sendall(struct.pack(">I", len(payload)) + payload)
        with peer.makefile("rb") as reply:
            size, = struct.unpack(">I", reply.read(4))
            response = json.loads(reply.read(size))
            if "error" in response:
                sys.exit(response["error"])
            print(response["ok"], flush=True)
    if json.loads((Path(sys.argv[2]) / "mirror_neuron_input.json").read_text()).get("hang"):
        time.sleep(10)
    """)

    File.chmod!(executable, 0o700)
    System.put_env("MN_WASMTIME_HOST_BIN", executable)
    track = start_supervised!({Agent, fn -> {nil, 0, 0} end})

    Application.put_env(:mirror_neuron, key, fn _, rpc, timeout ->
      request = Jason.decode!(rpc.resource_json)
      id = request["observation_id"]

      reply =
        case request["kind"] do
          "wit_skill" ->
            assert timeout == :infinity
            Agent.update(track, fn {_, calls, _} -> {id, calls + 1, 0} end)
            Process.sleep(1_800)
            %{"value" => %{"citations" => ["source"]}}

          "wit_model_status" ->
            assert timeout == 200

            count =
              Agent.get_and_update(track, fn {^id, calls, polls} ->
                {polls + 1, {id, calls, polls + 1}}
              end)

            %{
              "pending" => true,
              "preparation" => %{
                "preparation_id" => "weights",
                "kind" => "model",
                "purpose" => "embedding",
                "phase" => "downloading",
                "timeout_ms" => 700,
                "timeout_policy" => "download_inactivity",
                "current_bytes" => count * 100
              }
            }
        end

      {:ok, %Mirrorneuron.Cluster.V1.SetResourceResponse{resource_json: Jason.encode!(reply)}}
    end)

    config = %{
      "wasm_component" => "worker.wasm",
      "wasm_capabilities" => ["skill.workflow-context.query-knowledge"],
      "wit_skills" => [dep["name"]],
      "beacon_enabled" => true,
      "agent_beacon_required" => true,
      "beacon_interval_ms" => 100,
      "beacon_timeout_ms" => 600,
      "timeout_seconds" => 1
    }

    parent = self()

    opts = [
      job_id: "execution",
      agent_id: "worker",
      run_id: "workflow",
      payloads_path: root,
      event_callback: fn type, payload -> send(parent, {type, payload}) end
    ]

    assert {:ok, %{"stdout" => ~s({"citations":["source"]})}} =
             MirrorNeuron.Sandbox.Wasmtime.run(%{}, config, opts)

    assert_receive {"runtime_preparation_started",
                    %{"purpose" => "embedding", "source" => "runtime"}}

    assert_receive {"runtime_preparation_progress", %{"current_bytes" => _}}
    assert_receive {"runtime_preparation_finished", _}
    assert {_, 1, polls} = Agent.get(track, & &1)
    assert polls >= 3
    refute_received {:agent_beacon, %{"source" => "agent"}}

    assert {:error, %{"error" => "agent beacon deadline exceeded"}} =
             MirrorNeuron.Sandbox.Wasmtime.run(%{"hang" => true}, config, opts)
  end

  test "the model RPC has time to prepare weights within the WASI step" do
    key = :native_sdk_grpc_job_response_client
    old_client = Application.get_env(:mirror_neuron, key)
    old_target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    old_timeout = System.get_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS")

    on_exit(fn ->
      restore_env(key, old_client)
      restore_system_env("MN_NATIVE_SDK_GRPC_TARGET", old_target)
      restore_system_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS", old_timeout)
    end)

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")
    System.delete_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS")

    Application.put_env(:mirror_neuron, key, fn _, request, timeout ->
      assert Jason.decode!(request.resource_json)["scope"] == %{
               "job_id" => "definition",
               "execution_id" => "execution",
               "runtime_run_id" => "workflow"
             }

      assert timeout == :timer.minutes(15)
      {:ok, %Mirrorneuron.Cluster.V1.SetResourceResponse{resource_json: ~s({"value":{}})}}
    end)

    assert {:ok, "{}"} = call("model.generate-json", ["Return JSON.", "{}", "{}"])
  end

  test "native skill dispatch binds the executor, pinned dependency and method grant", %{
    record: record
  } do
    assert :ok = WitBroker.validate(["skill.temporal-graph.ingest-scan"])
    assert {:error, _} = WitBroker.validate(["skill.temporal-graph.*"])

    binding = %{executor: node(), skills: ["temporal_graph_skill"], access: "read_write"}

    request = fn native ->
      WitServices.call(
        "execution",
        "workflow",
        "skill.temporal-graph.ingest-scan",
        ["{}"],
        %{},
        native
      )
    end

    assert {:error, :invalid_native_skill_request} = request.(binding)

    dep = %{
      "name" => "temporal_graph_skill",
      "source" => "payload",
      "type" => "wit",
      "version" => "1.0.0",
      "sha256" => WitArtifacts.digest("component")
    }

    record =
      record
      |> put_in(["manifest", "skill_dependencies"], [dep])
      |> Map.put("job_data_access", "read")

    assert {:ok, _} = RedisStore.persist_job("execution", record)
    assert {:error, :invalid_native_skill_request} = request.(%{binding | skills: []})

    key = :native_sdk_grpc_job_response_client
    original = Application.get_env(:mirror_neuron, key)
    target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    on_exit(fn ->
      restore_env(key, original)
      restore_system_env("MN_NATIVE_SDK_GRPC_TARGET", target)
    end)

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

    Application.put_env(:mirror_neuron, key, fn _, rpc, _ ->
      payload = Jason.decode!(rpc.resource_json)

      assert payload["scope"] == %{
               "job_id" => "definition",
               "execution_id" => "execution",
               "runtime_run_id" => "workflow"
             }

      assert payload["run_data_ref"]["submission_id"] == "sub"
      assert payload["arguments"] == %{}
      assert payload["job_data_write"] == false
      assert payload["skill"] == "temporal-graph" and payload["operation"] == "ingest-scan"
      {:ok, %Mirrorneuron.Cluster.V1.SetResourceResponse{resource_json: ~s({"value":42})}}
    end)

    assert {:ok, "42"} = request.(binding)

    for {source, result} <- [
          {"skill", {:ok, "42"}},
          {"unknown", {:error, :invalid_native_skill_request}}
        ] do
      updated = put_in(record, ["manifest", "skill_dependencies"], [%{dep | "source" => source}])
      assert {:ok, _} = RedisStore.persist_job("execution", updated)
      assert request.(binding) == result
    end
  end

  test "knowledge retrieval exposes only its bounded embedding failure", %{record: record} do
    key = :native_sdk_grpc_job_response_client
    client = Application.get_env(:mirror_neuron, key)
    target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")

    on_exit(fn ->
      restore_env(key, client)
      restore_system_env("MN_NATIVE_SDK_GRPC_TARGET", target)
    end)

    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "127.0.0.1:55052")

    dep = %{
      "name" => "mn_sdk_workflow_context",
      "source" => "payload",
      "type" => "wit",
      "version" => "1.0.0",
      "sha256" => WitArtifacts.digest("component")
    }

    assert {:ok, _} =
             RedisStore.persist_job(
               "execution",
               put_in(record, ["manifest", "skill_dependencies"], [dep])
             )

    for {method, error, expected} <- [
          {"query-knowledge", "embedding_model_unavailable", :embedding_model_unavailable},
          {"query-knowledge", "private provider details", :native_skill_unavailable},
          {"read-state", "embedding_model_unavailable", :native_skill_unavailable}
        ] do
      Application.put_env(:mirror_neuron, key, fn _, _, _ ->
        {:ok,
         %Mirrorneuron.Cluster.V1.SetResourceResponse{
           resource_json: Jason.encode!(%{error: error})
         }}
      end)

      assert {:error, ^expected} =
               WitServices.call(
                 "execution",
                 "workflow",
                 "skill.workflow-context." <> method,
                 ["{}"],
                 %{},
                 %{executor: node(), skills: [dep["name"]], access: "read"}
               )
    end
  end

  test "preserves domain JSON reference kinds and verifies binary inputs", %{root: root} do
    assert {:ok, ref} =
             call("artifacts.commit-json", ["evidence/result.json", "block_result", "{}"])

    assert ref["kind"] == "block_result" and ref["version"] == "mn.committed_json/v1"

    assert {:error, _} =
             call("artifacts.commit-json", ["evidence/bad.json", "block_result", "bad json"])

    bytes = <<0, 255, 42>>
    dir = Path.join([root, "submissions/sub/outputs/runs/workflow"])
    File.write!(Path.join(dir, "blob.bin"), bytes)
    hash = WitArtifacts.digest(bytes)
    assert {:ok, "verified"} = call("artifacts.verify", ["blob.bin", hash, 3])
    assert {:error, _} = call("artifacts.verify", ["blob.bin", hash, 2])
    assert {:error, _} = call("artifacts.verify", ["blob.bin", String.duplicate("0", 64), 3])
    assert {:error, _} = call("artifacts.verify", ["../blob.bin", hash, 3])
  end

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
