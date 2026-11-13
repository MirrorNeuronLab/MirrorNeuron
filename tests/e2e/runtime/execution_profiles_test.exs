defmodule MirrorNeuron.Runtime.ExecutionProfilesTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore

  test "reports executor pool capacity in cluster inspection" do
    assert {:ok, nodes} = {:ok, MirrorNeuron.inspect_nodes()}

    assert Enum.any?(nodes, fn node ->
             node["self?"] || node[:self?]
           end)

    local_node =
      Enum.find(nodes, fn node ->
        (node["self?"] || node[:self?]) == true
      end)

    pools = local_node["executor_pools"] || local_node[:executor_pools]
    default_pool = pools["default"] || pools[:default]

    assert is_map(default_pool)
    assert (default_pool["capacity"] || default_pool[:capacity]) >= 1
  end

  test "runs a dependency-heavy sandbox worker only when its execution profile is advertised" do
    profile = "opencv-video-guardian-runtime-#{System.unique_integer([:positive])}"
    restore_profiles = put_test_profiles(%{profile => profile_config("registry.local/video:ok")})

    RedisStore.persist_node_state(to_string(Node.self()), %{
      "status" => "healthy",
      "profiles" => [profile],
      "profile_health" => %{profile => %{"status" => "healthy"}},
      "gpu" => false,
      "capabilities" => ["video-codec:h264"]
    })

    manifest = profiled_executor_manifest("profiled_runtime_success", profile)

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 5_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "profile"]) == profile
    assert get_in(job, ["result", "output", "image"]) == "registry.local/video:ok"

    assert {:ok, agent} = RedisStore.fetch_agent(job_id, "video_guardian")
    assert get_in(agent, ["metadata", "execution_profile"]) == profile
    assert agent["assigned_node"] == to_string(Node.self())

    RedisStore.delete_job(job_id)
    restore_profiles.()
  end

  test "pauses profiled work for review when no runtime node advertises the profile" do
    profile = "missing-opencv-profile-#{System.unique_integer([:positive])}"

    restore_profiles =
      put_test_profiles(%{profile => profile_config("registry.local/video:missing")})

    RedisStore.persist_node_state(to_string(Node.self()), %{
      "status" => "healthy",
      "profiles" => [],
      "profile_health" => %{},
      "gpu" => false,
      "capabilities" => []
    })

    manifest = profiled_executor_manifest("profiled_runtime_pauses", profile)

    assert {:ok, job_id} = run_manifest(manifest)

    wait_until(fn ->
      match?({:ok, %{"status" => "paused"}}, MirrorNeuron.inspect_job(job_id))
    end)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "paused"
    assert job["recovery_status"] == "paused_for_review"
    assert job["recovery_requires_review"] == true
    assert job["recovery_reason"] =~ "execution profile #{profile} has no eligible runtime nodes"

    assert {:ok, events} = MirrorNeuron.events(job_id)

    assert Enum.any?(events, fn event ->
             event["type"] == "job_paused_for_manual_restart" and
               event["execution_profile"] == profile
           end)

    RedisStore.delete_job(job_id)
    restore_profiles.()
  end

  test "waits for all agents to register before seeding entrypoints" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "fanout_registration_test",
      "entrypoints" => ["dispatcher"],
      "initial_inputs" => %{
        "dispatcher" => [%{"text" => "fan out"}]
      },
      "nodes" =>
        [
          %{
            "node_id" => "dispatcher",
            "agent_type" => "router",
            "role" => "root_coordinator",
            "config" => %{"emit_type" => "fanout"}
          },
          %{
            "node_id" => "sink",
            "agent_type" => "aggregator",
            "config" => %{"complete_after" => 4, "terminal_sink" => true, "complete_run" => true}
          }
        ] ++
          Enum.map(1..4, fn index ->
            %{"node_id" => "worker_#{index}", "agent_type" => "router"}
          end),
      "edges" =>
        Enum.flat_map(1..4, fn index ->
          [
            %{
              "from_node" => "dispatcher",
              "to_node" => "worker_#{index}",
              "message_type" => "fanout"
            },
            %{
              "from_node" => "worker_#{index}",
              "to_node" => "sink",
              "message_type" => "fanout"
            }
          ]
        end),
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)
    assert job["status"] == "completed"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    refute Enum.any?(events, &(&1["type"] == "dead_letter"))

    RedisStore.delete_job(job_id)
  end
end
