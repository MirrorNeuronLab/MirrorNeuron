defmodule MirrorNeuron.Scheduler.Placement.UsageTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Scheduler.Placement.Usage

  defp job(id, status, node, device, port) do
    %{
      "job_id" => id,
      "status" => status,
      "scheduler" => %{
        "placements" => [
          %{
            "node" => node,
            "resources" => %{"cpu_cores" => 2, "memory_mb" => 1024, "gpu_count" => 1},
            "allocations" => %{
              "devices" => [%{"id" => device}],
              "ports" => [%{"port" => port, "protocol" => "grpc"}]
            }
          }
        ]
      }
    }
  end

  test "paused placements retain capacity, ports and devices while terminal runs release them" do
    jobs =
      [job("paused", "paused", "pc-a", "gpu-a", 8080)] ++
        Enum.map(~w(completed failed cancelled), &job(&1, &1, "pc-a", "released", 9000))

    used = Usage.usage_from_jobs(jobs, []) |> Usage.usage_for_node("pc-a")

    assert used["resources"]["cpu_cores"] == 2
    assert used["resources"]["gpu_count"] == 1
    assert used["devices"] == MapSet.new(["gpu-a"])
    assert used["ports"] == MapSet.new(["tcp:8080"])
  end

  test "ignoring a replaced run preserves other runs and independent node reservations" do
    jobs = [
      job("replaced", "running", "pc-a", "old", 8080),
      job("retained", "running", "pc-a", "kept", 8081),
      job("remote", "running", "pc-b", "remote", 8080)
    ]

    used = Usage.usage_from_jobs(jobs, ["replaced"])
    assert used["pc-a"]["devices"] == MapSet.new(["kept"])
    assert used["pc-a"]["ports"] == MapSet.new(["tcp:8081"])
    assert used["pc-b"]["ports"] == MapSet.new(["tcp:8080"])
    assert Usage.usage_for_node(used, "missing")["resources"]["cpu_cores"] == 0
  end

  test "workers share a run's GPU while their CPU, RAM and ports remain accounted for" do
    initial = Map.put(Usage.empty_usage(), "share_devices", true)

    usage =
      Enum.reduce([8080, 8081], initial, fn port, used ->
        Usage.add_usage(used, %{"cpu_cores" => 2, "memory_mb" => 1024, "gpu_count" => 1}, %{
          "devices" => [%{"id" => "gpu-0"}],
          "ports" => [%{"port" => port}]
        })
      end)

    assert usage["resources"]["gpu_count"] == 1
    assert usage["resources"]["cpu_cores"] == 4
    assert usage["resources"]["memory_mb"] == 2048
    assert usage["devices"] == MapSet.new(["gpu-0"])
    assert usage["ports"] == MapSet.new(["tcp:8080", "tcp:8081"])
  end

  test "serialized reservations retain protocol aliases and device identity when merged" do
    left = %{"resources" => %{"cpu_cores" => 1}, "ports" => ["tcp:8080"], "devices" => ["gpu-a"]}

    right =
      Usage.add_usage(Usage.empty_usage(), %{"cpu_cores" => 2}, %{
        "ports" => [
          %{"port" => 8080, "protocol" => "HTTP"},
          %{"port" => 8080, "protocol" => "udp"}
        ],
        "devices" => [%{"id" => "gpu-b"}]
      })

    combined = Usage.merge_usage(left, right)
    assert combined["resources"]["cpu_cores"] == 3
    assert combined["ports"] == MapSet.new(["tcp:8080", "udp:8080"])
    assert combined["devices"] == MapSet.new(["gpu-a", "gpu-b"])
  end
end
