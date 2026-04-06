defmodule MirrorNeuron.MonitorTest do
  use ExUnit.Case

  alias MirrorNeuron.Monitor
  alias MirrorNeuron.Persistence.RedisStore

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for monitor tests"
    end
  end

  test "lists jobs with node and sandbox summaries" do
    job_id = "monitor-job-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "prime_demo",
      "status" => "running",
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:05Z"
    })

    RedisStore.persist_agent(job_id, "prime_worker_0001", %{
      "agent_id" => "prime_worker_0001",
      "agent_type" => "executor",
      "assigned_node" => "mn1@192.168.4.29",
      "processed_messages" => 1,
      "mailbox_depth" => 0,
      "current_state" => %{
        "runs" => 1,
        "last_result" => %{
          "sandbox_name" => "mirror-neuron-job-demo",
          "lease" => %{"pool" => "default", "lease_id" => "lease-1", "slots" => 1}
        }
      },
      "metadata" => %{"paused" => false}
    })

    RedisStore.append_event(job_id, %{
      "timestamp" => "2026-03-28T00:00:05Z",
      "type" => "sandbox_job_completed",
      "agent_id" => "prime_worker_0001",
      "payload" => %{
        "sandbox_name" => "mirror-neuron-job-demo",
        "exit_code" => 0,
        "pool" => "default"
      }
    })

    assert {:ok, jobs} = Monitor.list_jobs()
    summary = Enum.find(jobs, &(&1["job_id"] == job_id))

    assert summary["graph_id"] == "prime_demo"
    assert summary["nodes"] == ["mn1@192.168.4.29"]
    assert summary["sandbox_names"] == ["mirror-neuron-job-demo"]

    RedisStore.delete_job(job_id)
  end

  test "returns detailed job monitor view" do
    job_id = "monitor-job-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "llm_demo",
      "status" => "completed",
      "submitted_at" => "2026-03-28T00:00:00Z",
      "updated_at" => "2026-03-28T00:00:10Z"
    })

    RedisStore.persist_agent(job_id, "reviewer", %{
      "agent_id" => "reviewer",
      "agent_type" => "aggregator",
      "assigned_node" => "mn2@192.168.4.35",
      "processed_messages" => 3,
      "mailbox_depth" => 0,
      "current_state" => %{},
      "metadata" => %{"paused" => false}
    })

    RedisStore.persist_agent(job_id, "codegen_1", %{
      "agent_id" => "codegen_1",
      "agent_type" => "executor",
      "assigned_node" => "mn1@192.168.4.29",
      "processed_messages" => 1,
      "mailbox_depth" => 0,
      "current_state" => %{
        "runs" => 1,
        "last_result" => %{
          "sandbox_name" => "mirror-neuron-job-llm",
          "lease" => %{"pool" => "default", "lease_id" => "lease-2", "slots" => 1}
        }
      },
      "metadata" => %{"paused" => false}
    })

    RedisStore.append_event(job_id, %{
      "timestamp" => "2026-03-28T00:00:08Z",
      "type" => "sandbox_job_completed",
      "agent_id" => "codegen_1",
      "payload" => %{
        "sandbox_name" => "mirror-neuron-job-llm",
        "exit_code" => 0,
        "pool" => "default"
      }
    })

    RedisStore.append_event(job_id, %{
      "timestamp" => "2026-03-28T00:00:10Z",
      "type" => "job_completed",
      "agent_id" => "reviewer",
      "payload" => %{"count" => 3}
    })

    assert {:ok, details} = Monitor.job_details(job_id)
    assert details["summary"]["job_id"] == job_id

    assert Enum.any?(
             details["agents"],
             &(&1["agent_id"] == "codegen_1" and &1["sandbox_name"] == "mirror-neuron-job-llm")
           )

    assert Enum.any?(details["sandboxes"], &(&1["sandbox_name"] == "mirror-neuron-job-llm"))
    assert List.first(details["recent_events"])["type"] == "job_completed"

    RedisStore.delete_job(job_id)
  end
end
