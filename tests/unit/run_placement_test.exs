defmodule MirrorNeuron.Grpc.RunPlacementTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Runtime.{NodeAdmission, NodeAdmissionState}

  defmodule Store do
    def fetch_node_admission(_), do: Process.get(:placement_state, {:error, :unavailable})
  end

  setup do
    previous = Application.get_env(:mirror_neuron, :node_admission_store)
    Application.put_env(:mirror_neuron, :node_admission_store, Store)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mirror_neuron, :node_admission_store, previous),
        else: Application.delete_env(:mirror_neuron, :node_admission_store)
    end)

    :ok
  end

  defp project(status \\ "running") do
    JobProjection.run_detail(
      %{
        "job_id" => "run-1",
        "owner_node" => NodeAdmission.node_name(),
        "status" => status
      },
      "run-1"
    )["placement"]
  end

  defp reserve(mode \\ "shared") do
    allocation = %{
      "mode" => mode,
      "resources" => %{"cpu_cores" => 2.5, "memory_mb" => 8192, "disk_mb" => 1024},
      "devices" => [
        %{
          "kind" => "gpu",
          "reservation_memory_mb" => 4096,
          "memory_total_mb" => 16384,
          "models" => [%{"private" => "secret"}]
        },
        %{"kind" => "gpu", "memory_total_mb" => 8192},
        %{"kind" => "npu", "memory_total_mb" => 1024}
      ],
      "volumes" => [%{"path" => "/private/data"}]
    }

    held = %{"run_id" => "run-1", "allocation" => allocation, "generation" => 1}

    Process.put(
      :placement_state,
      {:ok, Map.put(NodeAdmissionState.new(), "reservations", %{"run-1" => held})}
    )
  end

  test "active and paused runs expose current numeric reservations without private allocation data" do
    reserve()

    for status <- ["pending", "running", "paused", "completed"] do
      placement = project(status)
      assert placement["owner_node"] == NodeAdmission.node_name()
      assert is_binary(placement["node_label"])

      assert placement["reservation"] == %{
               "state" => "reserved",
               "mode" => "shared",
               "cpu_cores" => 2.5,
               "memory_mb" => 8192,
               "disk_mb" => 1024,
               "gpu_count" => 2,
               "gpu_memory_mb" => 12288
             }

      refute Jason.encode!(placement) =~ "private"
      refute Jason.encode!(placement) =~ "secret"
    end

    reserve("exclusive_node")
    assert project()["reservation"]["mode"] == "exclusive_node"
  end

  test "released and queued runs have no reserved quantities" do
    state = NodeAdmissionState.new()
    Process.put(:placement_state, {:ok, state})
    assert project("completed")["reservation"] == %{"state" => "unreserved"}
    state = Map.put(state, "queue", [%{"run_id" => "run-1"}])
    Process.put(:placement_state, {:ok, state})
    assert project("queued")["reservation"] == %{"state" => "queued"}
  end

  test "unknown, legacy and remote-owner reservations cannot be reported as zero" do
    assert project()["reservation"] == %{"state" => "unavailable"}
    Process.put(:placement_state, {:ok, Map.put(NodeAdmissionState.new(), "legacy", ["run-1"])})
    assert project()["reservation"] == %{"state" => "unavailable"}
    reserve()

    remote =
      JobProjection.run_detail(%{"job_id" => "run-1", "owner_node" => "other@pc"}, "run-1")[
        "placement"
      ]

    assert remote == %{"owner_node" => "other@pc", "reservation" => %{"state" => "unavailable"}}
  end
end
