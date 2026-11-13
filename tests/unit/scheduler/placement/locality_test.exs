defmodule MirrorNeuron.Scheduler.Placement.LocalityTest do
  use MirrorNeuron.SchedulerCase, async: false

  test "prefers nodes with required blob refs after hard requirements match" do
    sha256 = String.duplicate("b", 64)

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "blob-locality",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "config" => %{}}
        ],
        "edges" => [],
        "metadata" => %{
          "mn_artifacts" => %{
            "blob_refs" => [
              %{
                "type" => "blob_ref",
                "sha256" => sha256,
                "size_bytes" => 10,
                "payload_path" => "input/video.mp4",
                "locations" => [
                  %{"node" => "node-b@lab", "storage" => "node_local", "path" => "bb/#{sha256}"}
                ]
              }
            ]
          }
        }
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [
                 %{"name" => "node-a@lab", "status" => "healthy", "hardware" => %{}},
                 %{"name" => "node-b@lab", "status" => "healthy", "hardware" => %{}}
               ],
               jobs: [],
               lookup_node_state: false
             )

    assert [%{"agent_id" => "worker", "node" => "node-b@lab", "blob_locality" => locality}] =
             plan["placements"]

    assert locality["local_count"] == 1
    assert locality["required_count"] == 1
  end

  test "treats shared filesystem blob refs as available on every node" do
    sha256 = String.duplicate("e", 64)

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "shared-blob-locality",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "config" => %{}}
        ],
        "edges" => [],
        "metadata" => %{
          "mn_artifacts" => %{
            "blob_refs" => [
              %{
                "type" => "blob_ref",
                "sha256" => sha256,
                "size_bytes" => 10,
                "payload_path" => "input/video.mp4",
                "locations" => [
                  %{"storage" => "shared_fs", "root" => "blob_store", "path" => "ee/#{sha256}"}
                ]
              }
            ]
          }
        }
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [
                 %{"name" => "node-a@lab", "status" => "healthy", "hardware" => %{}},
                 %{"name" => "node-b@lab", "status" => "healthy", "hardware" => %{}}
               ],
               jobs: [],
               lookup_node_state: false
             )

    assert [%{"agent_id" => "worker", "blob_locality" => locality}] = plan["placements"]
    assert locality["local_count"] == 1
    assert locality["required_count"] == 1
  end

  test "power-first scoring beats blob locality when both nodes are eligible" do
    sha256 = String.duplicate("c", 64)

    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "power-before-blob",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "config" => %{}}
        ],
        "edges" => [],
        "metadata" => %{
          "mn_artifacts" => %{
            "blob_refs" => [
              %{
                "type" => "blob_ref",
                "sha256" => sha256,
                "size_bytes" => 10,
                "payload_path" => "input/video.mp4",
                "locations" => [
                  %{"node" => "small@lab", "storage" => "node_local", "path" => "cc/#{sha256}"}
                ]
              }
            ]
          }
        }
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), large_node()],
               jobs: [],
               lookup_node_state: false
             )

    assert [%{"agent_id" => "worker", "node" => "large@lab", "blob_locality" => locality}] =
             plan["placements"]

    assert locality["local_count"] == 0
    assert locality["required_count"] == 1
  end
end
