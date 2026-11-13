defmodule MirrorNeuron.Runner.HostLocalTest.ContextTest do
  use MirrorNeuron.HostLocalCase, async: false

  alias MirrorNeuron.Runner.HostLocal

  test "installed handlers receive the invocation descriptor despite stale environment paths" do
    root =
      Path.join(System.tmp_dir!(), "host-local-descriptor-#{System.unique_integer([:positive])}")

    payloads = Path.join(root, "payloads")
    File.mkdir_p!(Path.join(payloads, "runtime"))

    File.write!(
      Path.join(payloads, "runtime/manifest.json"),
      ~s({"metadata":{"test":"invocation"}})
    )

    on_exit(fn -> File.rm_rf!(root) end)

    config = %{
      "upload_path" => ".",
      "upload_as" => ".",
      "workdir" => "/sandbox/job/runtime",
      "environment" => %{
        "MN_BUNDLE_ROOT" => "/stale/source/bundle",
        "MN_BLUEPRINT_MANIFEST_PATH" => "/stale/image/manifest.json"
      },
      "command" => [
        "sh",
        "-c",
        ~s(test "$MN_BLUEPRINT_MANIFEST_PATH" = "$MN_BUNDLE_ROOT/runtime/manifest.json" && test "$MN_BUNDLE_ROOT/runtime" -ef "$PWD" && cat "$MN_BLUEPRINT_MANIFEST_PATH")
      ]
    }

    assert {:ok, result} =
             HostLocal.run(%{}, config,
               job_id: "descriptor-job",
               agent_id: "installed-handler",
               payloads_path: payloads
             )

    assert Jason.decode!(result["stdout"])["metadata"]["test"] == "invocation"
  end

  test "auxiliary workers receive the physical workflow run without message headers" do
    config = %{
      "command" => [
        "sh",
        "-c",
        "printf '%s\\n' \"$MN_WORKFLOW_RUN_ID\" \"$MN_RUN_ID\""
      ],
      "environment" => %{
        "MN_RUN_ID" => "execution-id",
        "MN_WORKFLOW_RUN_ID" => "definition-time-label"
      }
    }

    assert {:ok, result} =
             HostLocal.run(%{}, config,
               job_id: "execution-id",
               agent_id: "auxiliary-service",
               run_id: "physical-workflow-run"
             )

    assert result["stdout"] == "physical-workflow-run\nexecution-id"
  end

  test "runtime workflow headers outrank configured environment and runner options" do
    message =
      MirrorNeuron.Message.new("execution-id", "source", "worker", "input", %{},
        headers: %{"mn.workflow.run_id" => "header-workflow-run"}
      )

    config = %{
      "command" => ["sh", "-c", "printf '%s\\n' \"$MN_WORKFLOW_RUN_ID\""],
      "environment" => %{"MN_WORKFLOW_RUN_ID" => "definition-time-label"}
    }

    assert {:ok, result} =
             HostLocal.run(%{}, config,
               job_id: "execution-id",
               agent_id: "worker",
               run_id: "option-workflow-run",
               message: message
             )

    assert result["stdout"] == "header-workflow-run"
  end

  test "provides the internal Core gRPC target while preserving an explicit override" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_host_local_grpc_target_test_#{System.unique_integer([:positive])}"
      )

    bundle_dir = Path.join(tmp_dir, "job_bundle")
    payloads_dir = Path.join(bundle_dir, "payloads")
    upload_dir = Path.join(payloads_dir, "bundle")
    old_core_host = System.get_env("MN_CORE_HOST")
    old_grpc_port = System.get_env("MN_GRPC_PORT")
    old_grpc_target = System.get_env("MN_GRPC_TARGET")

    try do
      File.mkdir_p!(Path.join(upload_dir, "scripts"))

      File.write!(
        Path.join(upload_dir, "scripts/read_grpc_target.py"),
        """
        import json
        import os
        print(json.dumps({"target": os.environ["MN_GRPC_TARGET"]}))
        """
      )

      System.put_env("MN_CORE_HOST", "0.0.0.0")
      System.put_env("MN_GRPC_PORT", "50123")
      System.delete_env("MN_GRPC_TARGET")

      config = %{
        "upload_path" => "bundle",
        "upload_as" => "bundle",
        "workdir" => "/sandbox/job/bundle",
        "command" => ["python3.12", "scripts/read_grpc_target.py"]
      }

      assert {:ok, result} =
               HostLocal.run(
                 %{},
                 config,
                 job_id: "job-host-local-grpc-target",
                 agent_id: "grpc-target-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert Jason.decode!(String.trim(result["stdout"])) == %{
               "target" => "127.0.0.1:50123"
             }

      explicit_config =
        Map.put(config, "environment", %{"MN_GRPC_TARGET" => "core.internal:55555"})

      assert {:ok, explicit_result} =
               HostLocal.run(
                 %{},
                 explicit_config,
                 job_id: "job-host-local-explicit-grpc-target",
                 agent_id: "explicit-grpc-target-worker",
                 bundle_root: bundle_dir,
                 payloads_path: payloads_dir
               )

      assert Jason.decode!(String.trim(explicit_result["stdout"])) == %{
               "target" => "core.internal:55555"
             }
    after
      restore_env("MN_CORE_HOST", old_core_host)
      restore_env("MN_GRPC_PORT", old_grpc_port)
      restore_env("MN_GRPC_TARGET", old_grpc_target)
      File.rm_rf!(tmp_dir)
    end
  end
end
