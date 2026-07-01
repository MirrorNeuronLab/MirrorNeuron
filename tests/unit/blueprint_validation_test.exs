defmodule MirrorNeuron.BlueprintValidationTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.{BlueprintValidation, JobBundle, Manifest}

  test "reports unmet cpu gpu memory and disk requirements" do
    manifest = %Manifest{
      requirements: %{
        "cpu" => %{"min_cores" => 8},
        "gpu" => %{"min_count" => 1},
        "memory" => %{"min_gb" => 32},
        "disk" => %{"min_gb" => 20}
      },
      metadata: %{}
    }

    snapshot = %{
      cpu: %{logical_processors: 4},
      gpu: [],
      memory: %{total_mb: 16 * 1024},
      disk: %{available_mb: 10 * 1024}
    }

    assert {:error, "requirements_not_met:" <> reason} =
             BlueprintValidation.check_requirements(manifest, snapshot)

    assert {:ok, report} = Jason.decode(String.trim(reason))
    assert report["ok"] == false
    assert Enum.any?(report["issues"], &(&1["code"] == "requirements.memory_insufficient"))
    memory = Enum.find(report["issues"], &(&1["location"]["path"] == "memory"))
    assert memory["expected"]["resource"] == "memory"
    assert memory["actual"]["resource"] == "memory"
    assert reason =~ "cpu"
    assert reason =~ "gpu"
    assert reason =~ "memory"
    assert reason =~ "disk"
  end

  test "hard NVIDIA CUDA GPU requirements match one working node strictly" do
    manifest = %Manifest{
      requirements: %{
        "gpu" => %{
          "min_count" => 1,
          "vendor" => "nvidia",
          "driver" => "cuda",
          "min_api_version" => "12.0",
          "api_version_operator" => ">",
          "min_memory_mb" => 49_152,
          "memory_operator" => ">",
          "enforcement" => "hard"
        }
      },
      metadata: %{}
    }

    no_nvidia = %{
      nodes: [
        gpu_node("amd@lab", vendor: "amd", driver: "rocm", api_version: "6.1", memory: 65_536)
      ]
    }

    exact_cuda = %{nodes: [gpu_node("cuda12@lab", api_version: "12.0", memory: 65_536)]}
    exact_memory = %{nodes: [gpu_node("cuda48@lab", api_version: "12.1", memory: 49_152)]}

    split_memory = %{
      nodes: [
        gpu_node("cuda24a@lab", api_version: "12.1", memory: 24_576),
        gpu_node("cuda24b@lab", api_version: "12.1", memory: 24_576)
      ]
    }

    passing = %{nodes: [gpu_node("h100@lab", api_version: "12.1", memory: 81_920)]}

    for snapshot <- [no_nvidia, exact_cuda, exact_memory, split_memory] do
      assert {:error, "requirements_not_met:" <> reason} =
               BlueprintValidation.check_requirements(manifest, snapshot)

      assert {:ok, report} = Jason.decode(String.trim(reason))
      assert Enum.any?(report["issues"], &(&1["code"] == "requirements.gpu_node_unavailable"))
    end

    assert :ok = BlueprintValidation.check_requirements(manifest, passing)
  end

  test "force metadata does not skip hard GPU requirements" do
    manifest = %Manifest{
      requirements: %{
        "gpu" => %{
          "min_count" => 1,
          "vendor" => "nvidia",
          "driver" => "cuda",
          "min_api_version" => "12.0",
          "api_version_operator" => ">",
          "min_memory_mb" => 49_152,
          "memory_operator" => ">",
          "enforcement" => "hard"
        }
      },
      metadata: %{"mn_validation" => %{"force" => true}}
    }

    assert {:error, "requirements_not_met:" <> _reason} =
             BlueprintValidation.check_requirements(manifest, %{nodes: []})
  end

  test "runs pattern validation but requires command validation before Core submission" do
    root = Path.join(System.tmp_dir!(), "mn-validation-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "payloads/validation"))

    File.write!(
      Path.join(root, "payloads/validation/check.sh"),
      """
      #!/bin/sh
      test "$VIDEO_SOURCE_URI" = "rtsp://127.0.0.1:8554/demo"
      """
    )

    File.chmod!(Path.join(root, "payloads/validation/check.sh"), 0o755)

    manifest_map = %{
      "manifest_version" => "1.0",
      "graph_id" => "validation",
      "entrypoints" => ["worker"],
      "policies" => %{"recovery_mode" => "local_restart"},
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "config" => %{
              "environment" => %{
                "VIDEO_SOURCE_URI" => "rtsp://127.0.0.1:8554/demo",
                "MN_BLUEPRINT_CONFIG_JSON" =>
                  ~s({"video_source":{"uri":"rtsp://127.0.0.1:8554/demo"}})
              }
            }
          }
        ]
      },
      "input_validation" => %{
        "rules" => [
          %{
            "name" => "rtsp_uri",
            "type" => "pattern",
            "path" => "video_source.uri",
            "pattern" => "^rtsp://"
          },
          %{
            "name" => "script_probe",
            "type" => "command",
            "command" => ["payloads/validation/check.sh"],
            "timeout_seconds" => 2
          }
        ]
      }
    }

    assert {:ok, manifest} = Manifest.load(manifest_map)
    bundle = %JobBundle{root_path: root, manifest: manifest}

    assert {:error, "input_validation_failed:" <> reason} =
             BlueprintValidation.run_input_validation(bundle)

    assert {:ok, report} = Jason.decode(String.trim(reason))

    assert Enum.any?(
             report["issues"],
             &(&1["code"] == "validator.command_prevalidation_required")
           )
  end

  test "force metadata skips validation and requirements" do
    manifest = %Manifest{
      requirements: %{"cpu" => 999_999},
      input_validation: %{"rules" => [%{"type" => "command", "command" => ["missing-command"]}]},
      metadata: %{"mn_validation" => %{"force" => true}}
    }

    assert :ok =
             BlueprintValidation.check_requirements(manifest, %{cpu: %{logical_processors: 1}})

    assert :ok = BlueprintValidation.run_input_validation(%JobBundle{manifest: manifest})
  end

  defp gpu_node(name, opts) do
    vendor = Keyword.get(opts, :vendor, "nvidia")
    driver = Keyword.get(opts, :driver, "cuda")
    api_version = Keyword.fetch!(opts, :api_version)
    memory = Keyword.fetch!(opts, :memory)

    %{
      "name" => name,
      "status" => "healthy",
      "scheduling_eligible" => true,
      "devices" => [
        %{
          "id" => "#{name}-gpu-0",
          "kind" => "gpu",
          "type" => "#{vendor}/gpu",
          "vendor" => vendor,
          "driver" => driver,
          "api_version" => api_version,
          "memory_total_mb" => memory,
          "memory_free_mb" => memory,
          "capabilities" => ["gpu", vendor, driver]
        }
      ]
    }
  end
end
