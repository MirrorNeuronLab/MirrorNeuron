defmodule MirrorNeuron.Persistence.RedisStore.AdmissionTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  @tag :blueprint_runtime
  test "only one writer can commit a reservation against the same owner ledger version" do
    owner = "admission-owner@test"
    assert {:ok, initial} = RedisStore.fetch_node_admission(owner)
    version = initial["version"]

    # Both writers propose spending the same capacity from the same snapshot.
    # The result must hold even if Redis receives their writes sequentially.
    results =
      ["run-a", "run-b"]
      |> Task.async_stream(fn run_id ->
        {:ok, proposal, %{"state" => "preparing"}} =
          Runtime.NodeAdmissionState.transition(initial, "submit_now", %{"run_id" => run_id})

        {run_id,
         RedisStore.compare_node_admission(owner, version, %{proposal | "version" => version + 1})}
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert {[{winner, :ok}], [{_loser, {:error, :admission_conflict}}]} =
             Enum.split_with(results, fn {_, result} -> result == :ok end)

    assert {:ok, stored} = RedisStore.fetch_node_admission(owner)
    assert stored["version"] == version + 1
    assert Map.keys(stored["reservations"]) == [winner]
  end

  @tag :blueprint_runtime
  test "queue repair and projection writes compare both ledger version and durable Run bytes" do
    owner = "repair-owner@test"
    id = "repair-witness"

    {:ok, _} =
      RedisStore.persist_job(id, %{
        "job_id" => id,
        "status" => "queued",
        "admission" => %{"owner_node" => owner}
      })

    {:ok, _, first} = RedisStore.fetch_admission_job(id)
    {:ok, state} = RedisStore.fetch_node_admission(owner)
    revision = state["version"]
    next = Map.put(state, "version", revision + 1)
    attrs = %{"kind" => "resource_wait", "target_run_id" => id, "owner_node" => owner}
    assert {:ok, projected} = RedisStore.write_queue_schedule(owner, revision, first, nil, attrs)
    {:ok, _} = RedisStore.persist_terminal_job(id, %{"status" => "cancelled"})

    assert {:error, :admission_run_changed} =
             RedisStore.compare_node_admission(owner, revision, next, first)

    for change <- [nil, Map.put(attrs, "not_before", "2099-01-01T00:00:00Z")] do
      assert {:error, :admission_run_changed} =
               RedisStore.write_queue_schedule(owner, revision, first, projected, change)
    end

    assert {:ok, ^projected} = RedisStore.fetch_schedule("queue_" <> id)
    {:ok, _, current} = RedisStore.fetch_admission_job(id)
    :ok = RedisStore.compare_node_admission(owner, revision, next, current)

    assert {:error, :admission_conflict} =
             RedisStore.write_queue_schedule(owner, revision, current, projected, nil)

    assert {:ok, nil} =
             RedisStore.write_queue_schedule(owner, revision + 1, current, projected, nil)

    assert {:error, :admission_run_changed} =
             RedisStore.write_queue_schedule(owner, revision + 1, {id, "missing"}, nil, attrs)

    assert {:error, _} = RedisStore.fetch_schedule("queue_" <> id)
  end

  @tag :blueprint_runtime
  test "scheduler admission reads durable reservations omitted from monitoring summaries" do
    alias MirrorNeuron.{Config, Manifest, Scheduler}

    first_port = Config.integer("MN_AUTO_PORT_START", :auto_port_start)
    job_id = "port-reservation-#{System.unique_integer([:positive])}"

    node = %{
      "name" => "reservation@lab",
      "status" => "healthy",
      "capabilities" => ["cpu"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 200_000}
      }
    }

    {:ok, manifest} =
      Manifest.load(%{
        "apiVersion" => "mn.workflow/v1",
        "kind" => "Workflow",
        "manifest_version" => "1.0",
        "graph_id" => "reservation-test",
        "entrypoints" => ["worker"],
        "flow" => %{
          "nodes" => [
            %{
              "node_id" => "worker",
              "agent_type" => "executor",
              "role" => "root",
              "resources" => %{
                "ports" => [%{"label" => "mcp", "port" => "auto", "protocol" => "http"}]
              }
            }
          ],
          "edges" => []
        }
      })

    reservation = %{
      "status" => "running",
      "scheduler" => %{
        "placements" => [
          %{
            "agent_id" => "existing",
            "node" => node["name"],
            "resources" => %{},
            "allocations" => %{"ports" => [%{"port" => first_port, "protocol" => "tcp"}]}
          }
        ]
      }
    }

    for status <- ["running", "paused"] do
      assert {:ok, _} = RedisStore.persist_job(job_id, Map.put(reservation, "status", status))
      assert {:ok, summary} = RedisStore.fetch_job_summary(job_id)
      refute Map.has_key?(summary["scheduler"], "placements")
      assert {:ok, plan} = Scheduler.plan(manifest, nodes: [node])

      assert get_in(plan, [
               "placements",
               Access.at(0),
               "allocations",
               "ports",
               Access.at(0),
               "port"
             ]) == first_port + 1
    end

    assert {:ok, _} = RedisStore.persist_job(job_id, Map.put(reservation, "status", "completed"))
    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [node])

    assert get_in(plan, ["placements", Access.at(0), "allocations", "ports", Access.at(0), "port"]) ==
             first_port
  end
end
