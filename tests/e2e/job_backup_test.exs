defmodule MirrorNeuron.JobBackupTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.{JobBackup, JobBundle, Manifest}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for job backup tests"
    end

    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_wait_replicas = Application.get_env(:mirror_neuron, :redis_wait_replicas)
    old_wait_timeout = Application.get_env(:mirror_neuron, :redis_wait_timeout_ms)
    old_bundle_cache = System.get_env("MN_BUNDLE_CACHE_DIR")

    tmp_dir =
      Path.join(System.tmp_dir!(), "mn_job_backup_test_#{System.unique_integer([:positive])}")

    namespace = "mirror_neuron_backup_test_#{System.unique_integer([:positive])}"

    File.mkdir_p!(tmp_dir)
    System.put_env("MN_BUNDLE_CACHE_DIR", Path.join(tmp_dir, "bundle_cache"))
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    Application.put_env(:mirror_neuron, :redis_wait_replicas, 0)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 100)

    on_exit(fn ->
      cleanup_namespace(namespace)
      File.rm_rf!(tmp_dir)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_bundle_cache)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:redis_wait_replicas, old_wait_replicas)
      restore_env(:redis_wait_timeout_ms, old_wait_timeout)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "export rejects running jobs and includes raw runtime and bundle", %{tmp_dir: tmp_dir} do
    {:ok, job_id, _bundle} = seed_backup_job(tmp_dir, "paused")
    {:ok, running_job_id, _bundle} = seed_backup_job(tmp_dir, "running")

    assert {:error, reason} = JobBackup.export_job(running_job_id)
    assert reason =~ "must be paused"

    assert {:ok, backup, bundle_files} = JobBackup.export_job(job_id)
    assert backup["schema_version"] == "mn.backup.v1"
    assert backup["runtime"]["job"]["job_id"] == job_id
    assert [%{"agent_id" => "node1"}] = backup["runtime"]["agents"]
    assert [%{"type" => "job_paused"}] = backup["runtime"]["events"]
    assert is_binary(bundle_files["manifest.json"])
    exported_manifest = Jason.decode!(bundle_files["manifest.json"])
    assert exported_manifest["apiVersion"] == "mn.workflow/v1"

    assert get_in(exported_manifest, ["flow", "graph", "schema"]) ==
             "mn.workflow.problem_graph/v1"

    assert get_in(exported_manifest, ["runtime", "bindings", "intake", "workers"])
           |> hd()
           |> Map.get("id") == "intake_worker"

    assert bundle_files["payloads/dummy.txt"] == "hello"
  end

  test "export rejects embedded workflow manifests that lost DAG fields" do
    job_id = "backup-incomplete-workflow-#{System.unique_integer([:positive])}"

    incomplete_manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "incomplete_workflow",
      "entrypoints" => ["node1"],
      "nodes" => [%{"node_id" => "node1", "agent_type" => "router"}],
      "edges" => []
    }

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => "incomplete_workflow",
               "job_name" => "incomplete_workflow",
               "status" => "paused",
               "submitted_at" => Runtime.timestamp(),
               "updated_at" => Runtime.timestamp(),
               "root_agent_ids" => ["node1"],
               "manifest" => incomplete_manifest
             })

    on_exit(fn -> RedisStore.delete_job(job_id) end)

    assert {:error, reason} = JobBackup.export_job(job_id)
    assert reason =~ "embedded mn.workflow/v1 manifest is missing contract, flow, or runtime"
  end

  test "restore generates a new paused clone with provenance and rewritten runtime", %{
    tmp_dir: tmp_dir
  } do
    {:ok, source_job_id, _bundle} = seed_backup_job(tmp_dir, "paused")
    {:ok, backup, bundle_files} = JobBackup.export_job(source_job_id)

    backup =
      put_in(backup, ["runtime", "events"], [
        %{
          "type" => "job_paused",
          "job_id" => source_job_id,
          "run_id" => "source-run"
        }
      ])

    assert {:ok, result} =
             JobBackup.restore_job(backup, bundle_files,
               blueprint_id: "restored_blueprint",
               run_id: "restored-run"
             )

    new_job_id = result["job_id"]
    refute new_job_id == source_job_id
    assert result["recovery"].action == :paused_for_review
    assert result["recovery"].reason == "job was restored from a backup and must remain paused"

    on_exit(fn ->
      _ = MirrorNeuron.cancel(new_job_id)
      RedisStore.delete_job(new_job_id)
    end)

    assert {:ok, restored_job} = RedisStore.fetch_job(new_job_id)
    assert restored_job["status"] == "paused"
    assert restored_job["lease_owner"] != "old-node"
    assert restored_job["recovery_status"] == "paused_for_review"
    assert restored_job["recovery_requires_review"] == true
    assert get_in(restored_job, ["recovery", "can_resume"]) == true

    assert get_in(restored_job, ["recovery", "reason"]) ==
             "job was restored from a backup and must remain paused"

    assert get_in(restored_job, ["manifest", "metadata", "mn_cli", "blueprint_id"]) ==
             "restored_blueprint"

    assert get_in(restored_job, ["manifest", "metadata", "mn_cli", "blueprint_run_id"]) ==
             "restored-run"

    assert get_in(restored_job, ["manifest", "flow", "graph", "schema"]) ==
             "mn.workflow.problem_graph/v1"

    assert get_in(restored_job, ["manifest", "runtime", "bindings", "intake", "workers"])
           |> hd()
           |> Map.get("id") == "intake_worker"

    assert get_in(restored_job, ["restore_provenance", "source", "job_id"]) == source_job_id

    assert {:ok, [agent]} = RedisStore.list_agents(new_job_id)
    assert agent["parent_job_id"] == new_job_id
    assert agent["assigned_node"] != "old-node"
    refute Map.has_key?(agent["metadata"], "lease_owner")
    refute Map.has_key?(agent["metadata"], "lease_epoch")

    assert {:ok, events} = RedisStore.read_events(new_job_id)

    assert Enum.any?(events, fn event ->
             event["job_id"] == new_job_id and event["run_id"] == "restored-run"
           end)

    assert Enum.any?(events, &(&1["type"] == "job_restored_from_backup"))
  end

  defp seed_backup_job(tmp_dir, status) do
    job_id = "backup-source-#{status}-#{System.unique_integer([:positive])}"
    bundle_dir = create_bundle(tmp_dir, job_id)
    assert {:ok, bundle} = JobBundle.load(bundle_dir)

    manifest = Manifest.to_map(bundle.manifest)
    manifest_ref = Runtime.bundle_ref(bundle.manifest, bundle)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "graph_id" => bundle.manifest.graph_id,
               "job_name" => bundle.manifest.job_name,
               "status" => status,
               "submitted_at" => Runtime.timestamp(),
               "updated_at" => Runtime.timestamp(),
               "root_agent_ids" => ["node1"],
               "manifest" => manifest,
               "manifest_ref" => manifest_ref,
               "topology" => Manifest.topology(bundle.manifest),
               "lease_owner" => "old-node",
               "lease_epoch" => 1,
               "lease" => %{"owner_id" => "old-node", "epoch" => 1}
             })

    assert {:ok, _agent} =
             RedisStore.persist_agent(job_id, "node1", %{
               "agent_id" => "node1",
               "node_id" => "node1",
               "agent_type" => "router",
               "processed_messages" => 0,
               "mailbox_depth" => 0,
               "pending_messages" => [],
               "inflight_message" => nil,
               "assigned_node" => "old-node",
               "parent_job_id" => job_id,
               "metadata" => %{
                 "paused" => true,
                 "lease_owner" => "old-node",
                 "lease_epoch" => 1
               }
             })

    assert {:ok, _event} = RedisStore.append_event(job_id, %{"type" => "job_paused"})
    {:ok, job_id, bundle}
  end

  defp create_bundle(tmp_dir, graph_id) do
    bundle_dir = Path.join(tmp_dir, graph_id)
    payloads_dir = Path.join(bundle_dir, "payloads")
    File.mkdir_p!(payloads_dir)

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => graph_id,
      "contract" => %{
        "inputs" => %{"folder" => %{"type" => "string"}},
        "outputs" => %{"primary" => %{"path" => "final_artifact.json"}}
      },
      "flow" => %{
        "entrypoint" => "intake",
        "nodes" => [
          %{
            "node_id" => "node1",
            "agent_type" => "router",
            "role" => "root_coordinator"
          }
        ],
        "edges" => [],
        "graph" => %{
          "schema" => "mn.workflow.problem_graph/v1",
          "mode" => "static_dag",
          "source" => "intake",
          "sink" => "write",
          "execution" => %{"strategy" => "parallel"},
          "dynamic" => %{"enabled" => false},
          "edges" => [%{"id" => "intake-to-write", "from" => "intake", "to" => "write"}]
        },
        "steps" => [
          %{
            "id" => "intake",
            "kind" => "stage",
            "label" => "Intake",
            "goal" => "Collect inputs",
            "action" => "intake",
            "run" => "intake",
            "control" => %{"required" => true, "retry" => %{"max_attempts" => 1}}
          },
          %{
            "id" => "write",
            "kind" => "sink",
            "label" => "Write",
            "goal" => "Write output",
            "action" => "write",
            "run" => "write",
            "join" => %{"mode" => "all_required"}
          }
        ]
      },
      "runtime" => %{
        "bindings" => %{
          "intake" => %{
            "type" => "team",
            "workers" => [%{"id" => "intake_worker", "role" => "Intake worker"}]
          },
          "write" => %{"type" => "single", "workers" => [%{"id" => "writer", "role" => "Writer"}]}
        }
      },
      "metadata" => %{
        "mn_cli" => %{
          "blueprint_id" => "source_blueprint",
          "blueprint_run_id" => "source-run"
        }
      },
      "entrypoints" => ["node1"]
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(payloads_dir, "dummy.txt"), "hello")
    bundle_dir
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> _ = Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end
end
