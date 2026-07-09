defmodule MirrorNeuron.Execution.ProfileTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Builtins.Executor
  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Execution.LeaseManager

  defmodule ConfigEchoRunner do
    def run(_payload, config, _opts) do
      payload =
        Map.take(config, [
          "execution_profile",
          "from",
          "pool",
          "pool_slots",
          "reuse_shared_sandbox",
          "persistent_workspace"
        ])

      {:ok,
       %{
         "sandbox_name" => "profile-config-echo",
         "exit_code" => 0,
         "stdout" =>
           Jason.encode!(%{
             "events" => [%{"type" => "profile_config_seen", "payload" => payload}]
           }),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  setup do
    original_profiles = Application.get_env(:mirror_neuron, :execution_profiles)
    original_node_profiles = System.get_env("MN_NODE_EXECUTION_PROFILES")
    original_capabilities = System.get_env("MN_NODE_CAPABILITIES")
    original_gpu = System.get_env("MN_NODE_GPU")

    on_exit(fn ->
      restore_app_env(:execution_profiles, original_profiles)
      restore_env("MN_NODE_EXECUTION_PROFILES", original_node_profiles)
      restore_env("MN_NODE_CAPABILITIES", original_capabilities)
      restore_env("MN_NODE_GPU", original_gpu)
    end)

    :ok
  end

  test "resolves a manifest execution profile into OpenShell and pool config" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "opencv-video-guardian" => %{
        "image" => "registry.local/business_facility_safety_video_guardian:2026-05",
        "pool" => "opencv_gpu",
        "pool_slots" => 1,
        "gpu" => true,
        "policy" => "policies/video-egress.yaml",
        "reuse_shared_sandbox" => true,
        "persistent_workspace" => true
      }
    })

    config = Profile.apply_to_config(%{"execution_profile" => "opencv-video-guardian"})

    assert config["execution_profile"] == "opencv-video-guardian"
    assert config["from"] == "registry.local/business_facility_safety_video_guardian:2026-05"
    assert config["pool"] == "opencv_gpu"
    assert config["pool_slots"] == 1
    assert config["gpu"] == true
    assert config["policy"] == Path.expand("policies/video-egress.yaml")
    assert config["reuse_shared_sandbox"] == true
    assert config["persistent_workspace"] == true
  end

  test "profile OpenShell settings override manifest supplied sandbox settings" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "privileged-video" => %{
        "image" => "registry.local/video-guardian:stable",
        "pool" => "opencv_gpu",
        "pool_slots" => 2,
        "policy" => "operator/policies/video.yaml",
        "ssh_key" => "operator/keys/video.pem",
        "remote" => %{"host" => "gpu-runtime.internal"},
        "reuse_shared_sandbox" => true,
        "persistent_workspace" => false,
        "sandbox_upload_path" => "/srv/mirror-neuron/uploads"
      }
    })

    config =
      Profile.apply_to_config(%{
        "execution_profile" => "privileged-video",
        "from" => "attacker.local/unsafe:latest",
        "image" => "attacker.local/unsafe-alias:latest",
        "pool" => "default",
        "pool_slots" => 99,
        "policy" => "payloads/attacker-policy.yaml",
        "ssh_key" => "payloads/attacker-key.pem",
        "remote" => %{"host" => "attacker.example"},
        "reuse_shared_sandbox" => false,
        "persistent_workspace" => true,
        "sandbox_upload_path" => "/tmp/attacker",
        "runner_module" => ConfigEchoRunner,
        "output_message_type" => nil
      })

    assert config["execution_profile"] == "privileged-video"
    assert config["from"] == "registry.local/video-guardian:stable"
    assert config["pool"] == "opencv_gpu"
    assert config["pool_slots"] == 2
    assert config["policy"] == Path.expand("operator/policies/video.yaml")
    assert config["ssh_key"] == Path.expand("operator/keys/video.pem")
    assert config["remote"] == %{"host" => "gpu-runtime.internal"}
    assert config["reuse_shared_sandbox"] == true
    assert config["persistent_workspace"] == false
    assert config["sandbox_upload_path"] == "/srv/mirror-neuron/uploads"
    assert config["runner_module"] == ConfigEchoRunner
    assert Map.has_key?(config, "output_message_type")
  end

  test "capability matching accepts only healthy nodes that advertise the required profile" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "opencv-video-guardian" => %{
        "gpu" => true,
        "required_capabilities" => ["video-codec:h264"]
      }
    })

    eligible = %{
      "node" => "video-a@test",
      "status" => "healthy",
      "profiles" => ["opencv-video-guardian"],
      "gpu" => true,
      "capabilities" => ["video-codec:h264", "ffmpeg"]
    }

    missing_profile = %{eligible | "node" => "general@test", "profiles" => []}
    missing_gpu = %{eligible | "node" => "cpu-only@test", "gpu" => false}
    missing_codec = %{eligible | "node" => "codec-missing@test", "capabilities" => ["ffmpeg"]}

    assert Profile.eligible_node?("opencv-video-guardian", eligible)
    refute Profile.eligible_node?("opencv-video-guardian", missing_profile)
    refute Profile.eligible_node?("opencv-video-guardian", missing_gpu)
    refute Profile.eligible_node?("opencv-video-guardian", missing_codec)
  end

  test "warmup failure removes a profile from this node advertisement" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "ready-profile" => %{"warmup_command" => "exit 0"},
      "broken-profile" => %{"warmup_command" => "echo broken && exit 7"}
    })

    System.put_env("MN_NODE_EXECUTION_PROFILES", "ready-profile,broken-profile")
    System.put_env("MN_NODE_GPU", "false")

    advertisement = Profile.node_advertisement()

    assert is_list(advertisement["profiles"])
    refute "broken-profile" in advertisement["profiles"]
    assert get_in(advertisement, ["profile_health", "ready-profile", "status"]) == "not_ready"
    assert get_in(advertisement, ["profile_health", "broken-profile", "status"]) == "not_ready"
  end

  test "executor uses profile pool and OpenShell config at runtime" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "opencv-video-guardian" => %{
        "image" => "registry.local/video-guardian:stable",
        "pool" => "opencv_cpu",
        "pool_slots" => 2,
        "reuse_shared_sandbox" => true,
        "persistent_workspace" => true
      }
    })

    manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"opencv_cpu" => 2}})

    node = %{
      node_id: "video_guardian",
      config: %{
        "execution_profile" => "opencv-video-guardian",
        :runner_module => ConfigEchoRunner,
        :lease_manager => manager,
        "output_message_type" => nil
      }
    }

    {:ok, state} = Executor.init(node)

    context = %{
      job_id: "profile-runtime-test",
      node: node,
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    assert {:ok, next_state, actions} =
             Executor.handle_message(%{type: "inspect", payload: %{}}, state, context)

    assert next_state.last_result["lease"]["pool"] == "opencv_cpu"
    assert next_state.last_result["lease"]["slots"] == 2

    assert {:event, :profile_config_seen, payload} =
             Enum.find(actions, &match?({:event, :profile_config_seen, _}, &1))

    assert payload["execution_profile"] == "opencv-video-guardian"
    assert payload["from"] == "registry.local/video-guardian:stable"
    assert payload["reuse_shared_sandbox"] == true
    assert payload["persistent_workspace"] == true

    assert_receive {:agent_event, "video_guardian", :executor_lease_requested,
                    %{"pool" => "opencv_cpu", "slots" => 2}}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp unique_name do
    :"execution-profile-test-#{System.unique_integer([:positive])}"
  end
end
