defmodule MirrorNeuron.MonitorTest.DetailsTest do
  use MirrorNeuron.MonitorCase, async: false

  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Persistence.RedisStore

  test "job details does not expose persisted embedded manifests" do
    job_id = "monitor-secret-manifest-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "secret_demo",
      "status" => "completed",
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:10Z",
      "manifest" => %{
        "metadata" => %{"api_key" => "MN_SECRET_TOKEN"},
        "nodes" => [
          %{
            "node_id" => "worker",
            "config" => %{"command" => "curl -H 'Authorization: Bearer MN_SECRET_TOKEN'"},
            "tool_bindings" => [%{"token" => "MN_SECRET_TOKEN"}]
          }
        ],
        "initial_inputs" => %{"worker" => [%{"prompt" => "use MN_SECRET_TOKEN"}]}
      },
      "manifest_ref" => %{"graph_id" => "secret_demo"}
    })

    assert {:ok, details} = Monitor.job_details(job_id)

    refute Map.has_key?(details["job"], "manifest")
    assert details["job"]["manifest_ref"] == %{"graph_id" => "secret_demo"}
    assert details["summary"]["job_id"] == job_id

    RedisStore.delete_job(job_id)
  end

  test "job details reads only the requested recent event window" do
    job_id = "monitor-event-window-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "event_window_demo",
      "status" => "completed",
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:05Z"
    })

    for seq <- 1..5 do
      RedisStore.append_event(job_id, %{
        "timestamp" => "2026-03-28T00:00:0#{seq}Z",
        "type" => "event_#{seq}",
        "seq" => seq
      })
    end

    assert {:ok, details} = Monitor.job_details(job_id, event_limit: 2)
    assert Enum.map(details["recent_events"], & &1["seq"]) == [5, 4]
    assert details["summary"]["last_event"] == "event_5"

    RedisStore.delete_job(job_id)
  end

  test "compact job details omit recursive workflow outputs and event payloads" do
    job_id = "monitor-compact-budget-#{System.unique_integer([:positive])}"

    recursive = %{
      "outputs" => %{
        "next" => %{
          "input" => %{
            "outputs" => %{"previous" => %{"blob" => String.duplicate("x", 2_000_000)}},
            "_mn_step" => %{
              "step_input" => %{"previous" => %{"blob" => String.duplicate("x", 2_000_000)}}
            }
          }
        }
      }
    }

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "compact_demo",
      "status" => "completed",
      "result" => recursive,
      "workflow_state" => %{
        "status" => "completed",
        "steps" => %{
          "publish" => %{
            "id" => "publish",
            "status" => "completed",
            "output" => recursive,
            "last_message" => recursive
          }
        }
      }
    })

    RedisStore.append_event(job_id, %{
      "type" => "workflow_step_attempt_completed",
      "payload" => recursive
    })

    assert {:ok, details} = Monitor.job_details(job_id, compact: true, event_limit: 10)
    encoded = Jason.encode!(details)

    assert byte_size(encoded) < 1_048_576
    refute Map.has_key?(details["job"], "result")
    refute Map.has_key?(details["job"]["workflow_state"]["steps"]["publish"], "output")
    refute String.contains?(encoded, String.duplicate("x", 1000))

    RedisStore.delete_job(job_id)
  end

  test "compact job details expose a bounded failure cause" do
    job_id = "monitor-compact-failure-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "failed_bootstrap",
      "status" => "failed",
      "result" => %{
        "error" => %{
          "category" => "timeout",
          "component" => "job_coordinator",
          "message" => "failed to start agent audit__end: :timeout",
          "agent_id" => "audit__end",
          "details" => String.duplicate("not-public", 100_000)
        }
      }
    })

    assert {:ok, details} = Monitor.job_details(job_id, compact: true, event_limit: 10)

    expected = %{
      "agent_id" => "audit__end",
      "category" => "timeout",
      "component" => "job_coordinator",
      "message" => "failed to start agent audit__end: :timeout"
    }

    assert details["job"]["failure"] == expected
    assert details["summary"]["failure"] == expected
    refute Map.has_key?(details["job"], "result")
    refute String.contains?(Jason.encode!(details), "not-public")

    RedisStore.delete_job(job_id)
  end
end
