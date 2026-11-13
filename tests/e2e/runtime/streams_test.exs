defmodule MirrorNeuron.Runtime.StreamsTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.RuntimeTest.StreamProducerRunner
  alias MirrorNeuron.RuntimeTest.StreamDetectorRunner
  alias MirrorNeuron.RuntimeTest.SlowBackpressureRunner
  alias MirrorNeuron.RuntimeTest.BlockedAnalysisRunner
  alias MirrorNeuron.RuntimeTest.PromptControlRunner

  test "accepts spec stream messages through the runtime and preserves stream metadata in events" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "stream_message_test",
      "nodes" => [
        %{"node_id" => "root", "agent_type" => "router", "role" => "root_coordinator"},
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
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
        event["type"] == "agent_message_received" and event["agent_id"] == "sink" and
          get_in(event, ["payload", "stream", "stream_id"]) == "stream-1"
      end)

    assert is_map(received), inspect(events, pretty: true)
    assert received["payload"]["stream"]["stream_id"] == "stream-1"
    assert received["payload"]["class"] == "stream"
    assert received["payload"]["content_type"] == "application/x-ndjson"

    RedisStore.delete_job(job_id)
  end

  test "runs the streaming peak demo manifest to completion" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "streaming_peak_runtime_test",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{
        "ingress" => [%{"scenario" => "runtime_stream_test"}]
      },
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "stream_start"}
        },
        %{
          "node_id" => "source",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => StreamProducerRunner,
            "output_message_type" => nil
          }
        },
        %{
          "node_id" => "detector",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => StreamDetectorRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "source", "message_type" => "stream_start"},
        %{"from_node" => "source", "to_node" => "detector", "message_type" => "telemetry_chunk"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 3_000)
    assert job["status"] == "completed"
    assert get_in(job, ["result", "output", "chunks_received"]) == 2
    assert get_in(job, ["result", "output", "peak_detected"]) == true

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "stream_chunk_processed"))
    assert Enum.any?(events, &(&1["type"] == "agent_message_received"))

    RedisStore.delete_job(job_id)
  end

  test "live external input receives retry-later when stream agent is under backpressure" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "stream_live_backpressure_runtime_test",
      "type" => "service",
      "entrypoints" => ["slow_consumer"],
      "initial_inputs" => %{
        "slow_consumer" => [%{"value" => "warmup"}]
      },
      "nodes" => [
        %{
          "node_id" => "slow_consumer",
          "agent_type" => "executor",
          "type" => "stream",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => SlowBackpressureRunner,
            "output_message_type" => nil,
            "backpressure" => %{
              "max_queue_depth" => 4,
              "high_watermark" => 2,
              "low_watermark" => 1,
              "retry_after_ms" => 125
            }
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    results =
      1..16
      |> Task.async_stream(
        fn index ->
          MirrorNeuron.send_message(job_id, "slow_consumer", %{"value" => index})
        end,
        max_concurrency: 16,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.any?(results, &match?({:error, {:retry_later, _details}}, &1))
    assert Enum.any?(results, &match?({:ok, "delivered"}, &1))

    assert {:ok, pressure} = MirrorNeuron.pressure(job_id)
    assert is_map(pressure["agents"]["slow_consumer"])

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)

        Enum.any?(events, &(&1["type"] == "external_input_rejected")) and
          Enum.any?(events, &(&1["type"] == "backpressure_state"))
      end,
      2_000
    )

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  test "declared prompt controls are delivered while downstream analysis is blocked" do
    name = {BlockedAnalysisRunner, :test_owner}
    assert :yes = :global.register_name(name, self())
    on_exit(fn -> :global.unregister_name(name) end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "prompt_control_backpressure",
      "type" => "service",
      "entrypoints" => ["ingress", "gpu"],
      "initial_inputs" => %{"ingress" => [], "gpu" => [%{"frame" => 1}]},
      "contract" => %{
        "live_inputs" => %{
          "focus" => %{
            "entrypoint" => "ingress",
            "message_type" => "goal_update",
            "schema" => %{
              "type" => "object",
              "required" => ["instruction"],
              "additionalProperties" => false,
              "properties" => %{"instruction" => %{"type" => "string", "maxLength" => 500}}
            }
          }
        }
      },
      "nodes" => [
        %{
          "node_id" => "ingress",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "config" => %{"emit_type" => "goal_update"}
        },
        %{
          "node_id" => "gpu",
          "agent_type" => "executor",
          "type" => "stream",
          "config" => %{
            "runner_module" => BlockedAnalysisRunner,
            "output_message_type" => nil,
            "backpressure" => %{
              "max_queue_depth" => 4,
              "high_watermark" => 2,
              "low_watermark" => 0
            }
          }
        },
        %{
          "node_id" => "prompt",
          "agent_type" => "executor",
          "type" => "stream",
          "config" => %{"runner_module" => PromptControlRunner, "output_message_type" => nil}
        }
      ],
      "edges" => [
        %{"from_node" => "ingress", "to_node" => "gpu", "message_type" => "frame"},
        %{"from_node" => "ingress", "to_node" => "prompt", "message_type" => "goal_update"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)

    on_exit(fn ->
      MirrorNeuron.cancel(job_id)
      RedisStore.delete_job(job_id)
    end)

    assert_receive {:analysis_blocked, blocked}, 2_000
    # Delivery v2 includes the leased invocation in durable depth. One active
    # frame stays below the watermark; the second frame establishes pressure.
    wait_until(
      fn ->
        {:ok, pressure} = MirrorNeuron.pressure(job_id)
        get_in(pressure, ["agents", "gpu", "backpressure"]) == false
      end,
      2_000
    )

    assert {:ok, "delivered"} = MirrorNeuron.send_message(job_id, "gpu", %{"frame" => 2})

    wait_until(
      fn ->
        {:ok, pressure} = MirrorNeuron.pressure(job_id)
        get_in(pressure, ["agents", "gpu", "backpressure"]) == true
      end,
      2_000
    )

    payload = %{"instruction" => "Check helmet use"}
    assert {:error, {:retry_later, _}} = MirrorNeuron.send_message(job_id, "ingress", payload)

    assert {:ok, %{"status" => "accepted"}} =
             MirrorNeuron.Runtime.LiveInput.send(job_id, "focus", payload, "focus-1")

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)
        Enum.any?(events, &(&1["type"] == "prompt_control_applied"))
      end,
      2_000
    )

    assert Process.alive?(blocked)
    send(blocked, :release_analysis)
  end
end
