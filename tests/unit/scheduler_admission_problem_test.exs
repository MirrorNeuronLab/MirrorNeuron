defmodule MirrorNeuron.Scheduler.AdmissionProblemTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Scheduler.AdmissionProblem

  test "scalar measurements subtract reservations and distinguish busy from missing hardware" do
    node = %{
      "display_name" => "spark",
      "capacity" => %{"memory_mb" => 8192, "cpu_cores" => 8, "gpu_count" => 1, "disk_mb" => 1024}
    }

    used = %{"resources" => %{"memory_mb" => 6144, "cpu_cores" => 6, "gpu_count" => 1}}

    demand = %{
      "resources" => %{"memory_mb" => 4096, "cpu_cores" => 4, "gpu_count" => 1, "disk_mb" => 2048}
    }

    blockers =
      AdmissionProblem.allocation_blockers(
        {:error, :insufficient_resources},
        node,
        used,
        demand,
        1,
        fn _, _ -> true end
      )

    assert %{
             "code" => "MN_RESOURCE_EXHAUSTED",
             "available" => 2.0,
             "required" => 4.0,
             "unit" => "GiB"
           } = Enum.find(blockers, &(&1["resource"] == "memory_mb"))

    assert %{
             "code" => "MN_RESOURCE_EXHAUSTED",
             "available" => 2.0,
             "required" => 4.0,
             "unit" => "cores"
           } = Enum.find(blockers, &(&1["resource"] == "cpu_cores"))

    assert %{"code" => "MN_RESOURCE_EXHAUSTED", "available" => +0.0, "unit" => "devices"} =
             Enum.find(blockers, &(&1["resource"] == "gpu_count"))

    assert %{"code" => "MN_DISK_UNAVAILABLE", "available" => 1.0, "required" => 2.0} =
             Enum.find(blockers, &(&1["resource"] == "disk_mb"))

    demand = %{"resources" => %{"cpu_cores" => 16}}

    assert [%{"code" => "MN_CPU_REQUIREMENT_UNMET"}] =
             AdmissionProblem.allocation_blockers(
               {:error, :insufficient_resources},
               node,
               used,
               demand,
               1,
               fn _, _ -> true end
             )
  end

  test "reports are bounded and do not expose unsafe display names" do
    blocker =
      AdmissionProblem.blocker(
        "MN_PLACEMENT_UNSATISFIED",
        %{"display_name" => "/private/token=secret"},
        1
      )

    refute Map.has_key?(blocker, "node_label")

    [_, encoded] =
      String.split(AdmissionProblem.encode(List.duplicate(blocker, 101)), "mn_admission_v1:")

    assert length(Jason.decode!(encoded)["blockers"]) == 100
    assert Jason.decode!(encoded)["truncated"]
    refute encoded =~ "secret"
  end
end
