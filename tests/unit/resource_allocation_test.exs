defmodule MirrorNeuron.Runtime.ResourceAllocationTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.{ResourceAllocation, NodeAdmissionState}

  defp gpu(id, memory),
    do: %{
      "id" => id,
      "kind" => "gpu",
      "vendor" => "nvidia",
      "driver" => "cuda",
      "memory_total_mb" => memory,
      "memory_free_mb" => memory,
      "capabilities" => ["gpu", "cuda"]
    }

  defp capacity do
    %{
      "resources" => %{"cpu_cores" => 8, "memory_mb" => 65536, "disk_mb" => 1_048_576},
      "available" => %{"memory_mb" => 65536, "disk_mb" => 1_048_576},
      "devices" => [gpu("gpu-0", 49152), gpu("gpu-1", 24576)],
      "gpu_ratio" => 1,
      "managed_usage" => %{}
    }
  end

  defp request(memory, extra \\ %{}) do
    Map.merge(
      %{
        "mode" => "shared",
        "cpu_cores" => 1,
        "memory_mb" => 2048,
        "disk_mb" => 0,
        "devices" => [
          %{
            "driver" => "cuda",
            "vendor" => "nvidia",
            "count" => 1,
            "sharing" => "shared",
            "reservation_memory_mb" => memory
          }
        ]
      },
      extra
    )
  end

  defp entry(id, request, cap \\ capacity()),
    do: %{"run_id" => id, "job_name" => id, "request" => request, "capacity" => cap}

  test "packs on the smallest compatible GPU and admits compatible runs together" do
    {:ok, first} = ResourceAllocation.allocate(request(12288), capacity(), [])
    assert hd(first["devices"])["id"] == "gpu-1"
    {:ok, second} = ResourceAllocation.allocate(request(18432), capacity(), [first])
    assert hd(second["devices"])["id"] == "gpu-0"
    assert {:ok, _} = ResourceAllocation.allocate(request(8192), capacity(), [first, second])
    assert {:error, _} = ResourceAllocation.allocate(request(49152), capacity(), [])
  end

  test "GPU type is mandatory and two small GPUs cannot satisfy one large request" do
    wrong = put_in(request(4096), ["devices", Access.at(0), "driver"], "metal")
    assert %{"status" => "not_runnable"} = ResourceAllocation.check(wrong, capacity(), [])

    assert %{"status" => "not_runnable"} =
             ResourceAllocation.check(request(65536), capacity(), [])

    assert {:ok, %{"devices" => []}} =
             ResourceAllocation.allocate(request(0, %{"devices" => []}), capacity(), [])
  end

  test "shared weights are charged once but private contexts remain reserved" do
    cap = Map.put(capacity(), "shared_model_keys", %{"gpu-0" => ["engine-digest-settings"]})
    req =
      request(16384)
      |> put_in(["devices", Access.at(0), "ids"], ["gpu-0"])
      |> put_in(["devices", Access.at(0), "models"], [
        %{"key" => "engine-digest-settings", "memory_mb" => 12288}
      ])

    {:ok, first} = ResourceAllocation.allocate(req, cap, [])
    {:ok, second} = ResourceAllocation.allocate(req, cap, [first])
    assert hd(second["devices"])["incremental_memory_mb"] == 4096
    assert {:ok, _} = ResourceAllocation.allocate(req, cap, [first, second])
    {:ok, unverified} = ResourceAllocation.allocate(req, capacity(), [first])
    assert hd(unverified["devices"])["incremental_memory_mb"] == 16384
  end

  test "unknown telemetry is unavailable and pending reservations cannot be spent twice" do
    cap = put_in(capacity(), ["available", "memory_mb"], nil)
    assert %{"status" => "unavailable"} = ResourceAllocation.check(request(4096), cap, [])
    {:ok, first} = ResourceAllocation.allocate(request(16384), capacity(), [])

    cap =
      Map.update!(
        capacity(),
        "devices",
        &Enum.map(&1, fn d -> Map.put(d, "memory_free_mb", 16384) end)
      )

    assert %{"status" => "runnable_later"} =
             ResourceAllocation.check(request(16384), cap, [first])
  end

  test "releasing one run preserves another reservation and immediately makes capacity reusable" do
    cap = %{capacity() | "devices" => [gpu("gpu-0", 49152)]}

    {:ok, state, a} =
      NodeAdmissionState.transition(
        NodeAdmissionState.new(),
        "submit",
        entry("a", request(16384), cap)
      )

    {:ok, state, b} =
      NodeAdmissionState.transition(state, "submit", entry("b", request(16384), cap))

    assert a["state"] == "preparing" and b["state"] == "preparing"

    assert {:error, {:admission_blocked, _}} =
             NodeAdmissionState.transition(state, "submit_now", entry("c", request(16384), cap))

    {:ok, state, _} =
      NodeAdmissionState.transition(state, "release", %{
        "run_id" => "a",
        "generation" => a["generation"]
      })

    {:ok, state, c} =
      NodeAdmissionState.transition(state, "submit_now", entry("c", request(16384), cap))

    assert c["state"] == "preparing"
    assert Map.keys(state["reservations"]) |> Enum.sort() == ["b", "c"]

    assert {:error, :stale_node_reservation} =
             NodeAdmissionState.transition(state, "release", %{
               "run_id" => "c",
               "generation" => a["generation"]
             })
  end

  test "active inference must drain before a reservation is released" do
    {:ok, state, held} =
      NodeAdmissionState.transition(NodeAdmissionState.new(), "submit", entry("a", request(4096)))

    {:ok, state, _} =
      NodeAdmissionState.transition(state, "request_acquire", %{
        "run_id" => "a",
        "token" => "lease",
        "generation" => held["generation"]
      })

    assert {:error, :node_requests_active} =
             NodeAdmissionState.transition(state, "release", %{
               "run_id" => "a",
               "generation" => held["generation"]
             })

    {:ok, state, _} =
      NodeAdmissionState.transition(state, "request_release", %{"token" => "lease"})

    assert {:ok, _, _} =
             NodeAdmissionState.transition(state, "release", %{
               "run_id" => "a",
               "generation" => held["generation"]
             })
  end

  test "the previous whole-PC holder is upgraded without weakening protection" do
    old = %{
      "version" => 4,
      "generation" => 2,
      "holder" => %{"run_id" => "old", "generation" => 2},
      "queue" => [],
      "deferred" => [],
      "requests" => %{},
      "legacy" => []
    }

    upgraded = NodeAdmissionState.upgrade(old)
    assert upgraded["reservations"]["old"]["allocation"]["mode"] == "exclusive_node"

    assert {:error, {:admission_blocked, _}} =
             NodeAdmissionState.transition(upgraded, "submit_now", entry("new", request(4096)))
  end

  test "bounded backfill protects an older GPU run while CPU-only work still progresses" do
    cap = %{capacity() | "devices" => [gpu("gpu-0", 49152)]}

    {:ok, state, first} =
      NodeAdmissionState.transition(
        NodeAdmissionState.new(),
        "submit",
        entry("first", request(30720), cap)
      )

    {:ok, state, waiting} =
      NodeAdmissionState.transition(state, "submit", entry("older", request(20480), cap))

    assert waiting["state"] == "queued"

    state =
      Enum.reduce(1..3, state, fn number, state ->
        {:ok, next, receipt} =
          NodeAdmissionState.transition(
            state,
            "submit",
            entry("small-#{number}", request(1024), cap)
          )

        assert receipt["state"] == "preparing"
        next
      end)

    assert {:error, {:admission_blocked, _}} =
             NodeAdmissionState.transition(
               state,
               "submit_now",
               entry("fourth", request(1024), cap)
             )

    {:ok, state, cpu} =
      NodeAdmissionState.transition(
        state,
        "submit_now",
        entry("cpu", request(0, %{"devices" => []}), cap)
      )

    assert cpu["state"] == "preparing"

    {:ok, state, _} =
      NodeAdmissionState.transition(state, "release", %{
        "run_id" => "first",
        "generation" => first["generation"]
      })

    {:ok, state, _} = NodeAdmissionState.transition(state, "promote", %{"capacity" => cap})
    assert state["reservations"]["older"]
  end

  test "ports and overlapping writable folders stay exclusive across shared runs" do
    req =
      request(0, %{
        "devices" => [],
        "ports" => [%{"label" => "api", "port" => 8080, "protocol" => "http"}],
        "volumes" => [%{"source" => "/data/shared", "mode" => "rw"}]
      })

    {:ok, held} = ResourceAllocation.allocate(req, capacity(), [])

    conflict =
      request(0, %{
        "devices" => [],
        "ports" => [%{"label" => "other", "port" => 8080, "protocol" => "tcp"}]
      })

    assert {:error, [%{"resource" => "port"}]} =
             ResourceAllocation.allocate(conflict, capacity(), [held])

    conflict =
      request(0, %{
        "devices" => [],
        "volumes" => [%{"source" => "/data/shared/child", "mode" => "ro"}]
      })

    assert {:error, [%{"resource" => "writable_volume"}]} =
             ResourceAllocation.allocate(conflict, capacity(), [held])
  end
end
