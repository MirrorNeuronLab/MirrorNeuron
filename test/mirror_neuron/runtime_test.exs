defmodule MirrorNeuron.RuntimeTest do
  use ExUnit.Case

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} ->
        :ok

      _ ->
        raise "Redis must be running for runtime tests"
    end
  end

  test "runs a manifest to completion and persists job state" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "research_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{
        "ingress" => [%{"text" => "Summarize charging adoption"}]
      },
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "research_request"}
        },
        %{"node_id" => "router", "agent_type" => "router"},
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "router", "message_type" => "research_request"},
        %{"from_node" => "router", "to_node" => "sink", "message_type" => "research_request"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
    assert job_id =~ "research_test-"
    assert job["status"] == "completed"

    assert {:ok, persisted_job} = MirrorNeuron.inspect_job(job_id)
    assert persisted_job["status"] == "completed"

    assert {:ok, agents} = MirrorNeuron.inspect_agents(job_id)
    assert Enum.any?(agents, &(&1["agent_id"] == "ingress"))
    assert Enum.any?(agents, &(&1["agent_id"] == "sink"))

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "job_completed"))

    RedisStore.delete_job(job_id)
  end

  test "queues messages while paused and completes after resume" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "pause_resume_test",
      "nodes" => [
        %{
          "node_id" => "root",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "manual_result"}
        },
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)

    assert {:ok, "delivered"} =
             MirrorNeuron.send_message(job_id, "sink", %{
               "type" => "manual_result",
               "payload" => %{"text" => "approved while paused"}
             })

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "completed"

    RedisStore.delete_job(job_id)
  end

  test "accepts spec stream messages through the runtime and preserves stream metadata in events" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "stream_message_test",
      "nodes" => [
        %{"node_id" => "root", "agent_type" => "router", "role" => "root_coordinator"},
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = MirrorNeuron.run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end)

    stream_message =
      Message.new(job_id, "external-client", "sink", "progress_chunk", "{\"checked\":10}\n",
        class: "stream",
        content_type: "application/x-ndjson",
        headers: %{"schema_ref" => "com.test.progress", "schema_version" => "1.0.0"},
        stream: %{"stream_id" => "stream-1", "seq" => 1, "open" => true, "close" => false}
      )

    assert {:ok, "delivered"} = MirrorNeuron.send_message(job_id, "sink", stream_message)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 2_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "last_message"]) == "{\"checked\":10}\n"

    assert {:ok, events} = MirrorNeuron.events(job_id)

    received =
      Enum.find(events, fn event ->
        event["type"] == "agent_message_received" and event["agent_id"] == "sink"
      end)

    assert received["payload"]["stream"]["stream_id"] == "stream-1"
    assert received["payload"]["class"] == "stream"
    assert received["payload"]["content_type"] == "application/x-ndjson"

    RedisStore.delete_job(job_id)
  end

  test "reports executor pool capacity in cluster inspection" do
    assert {:ok, nodes} = {:ok, MirrorNeuron.inspect_nodes()}

    assert Enum.any?(nodes, fn node ->
             node["self?"] || node[:self?]
           end)

    local_node =
      Enum.find(nodes, fn node ->
        (node["self?"] || node[:self?]) == true
      end)

    pools = local_node["executor_pools"] || local_node[:executor_pools]
    default_pool = pools["default"] || pools[:default]

    assert is_map(default_pool)
    assert (default_pool["capacity"] || default_pool[:capacity]) >= 1
  end

  test "waits for all agents to register before seeding entrypoints" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "fanout_registration_test",
      "entrypoints" => ["dispatcher"],
      "initial_inputs" => %{
        "dispatcher" => [%{"text" => "fan out"}]
      },
      "nodes" =>
        [
          %{
            "node_id" => "dispatcher",
            "agent_type" => "router",
            "role" => "root_coordinator",
            "config" => %{"emit_type" => "fanout"}
          },
          %{
            "node_id" => "sink",
            "agent_type" => "aggregator",
            "config" => %{"complete_after" => 4}
          }
        ] ++
          Enum.map(1..4, fn index ->
            %{"node_id" => "worker_#{index}", "agent_type" => "router"}
          end),
      "edges" =>
        Enum.flat_map(1..4, fn index ->
          [
            %{
              "from_node" => "dispatcher",
              "to_node" => "worker_#{index}",
              "message_type" => "fanout"
            },
            %{
              "from_node" => "worker_#{index}",
              "to_node" => "sink",
              "message_type" => "fanout"
            }
          ]
        end),
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(manifest, await: true, timeout: 2_000)
    assert job["status"] == "completed"

    assert {:ok, events} = MirrorNeuron.events(job_id)
    refute Enum.any?(events, &(&1["type"] == "dead_letter"))

    RedisStore.delete_job(job_id)
  end

  defp running_status?(job_id) do
    case MirrorNeuron.inspect_job(job_id) do
      {:ok, %{"status" => "running"}} -> true
      _ -> false
    end
  end

  defp wait_until(fun, timeout \\ 1_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_until(fun, started_at, timeout)
  end

  defp do_wait_until(fun, started_at, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout do
        flunk("condition was not met within #{timeout}ms")
      else
        Process.sleep(20)
        do_wait_until(fun, started_at, timeout)
      end
    end
  end
end
