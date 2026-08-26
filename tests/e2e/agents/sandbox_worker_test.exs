defmodule MirrorNeuron.ExecutorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Executor
  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Message

  defmodule FlakyRunner do
    def run(_payload, _config, _opts) do
      attempt = Process.get(:sandbox_worker_attempt, 0) + 1
      Process.put(:sandbox_worker_attempt, attempt)

      case attempt do
        1 ->
          {:error,
           %{
             "error" => "status: Unknown",
             "logs" => "h2 protocol error: error reading a body from connection"
           }}

        _ ->
          {:ok,
           %{
             "sandbox_name" => "test-sandbox",
             "exit_code" => 0,
             "stdout" => "{}",
             "stderr" => "",
             "logs" => ""
           }}
      end
    end
  end

  defmodule HardFailRunner do
    def run(_payload, _config, _opts) do
      attempt = Process.get(:sandbox_worker_attempt, 0) + 1
      Process.put(:sandbox_worker_attempt, attempt)
      {:error, %{"error" => "missing script", "logs" => "python3.11: can't open file"}}
    end
  end

  defmodule LargeFallbackRunner do
    def run(_payload, _config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "large-fallback-runner",
         "exit_code" => 0,
         "stdout" => "{}",
         "stderr" => "",
         "logs" => String.duplicate("x", 1_100_000)
       }}
    end
  end

  defmodule SharedResultRunner do
    def run(_payload, config, _opts) do
      environment = Map.fetch!(config, "environment")
      submission = Map.fetch!(environment, "MN_JOB_SHARED_STORAGE_ROOT")
      pointer = Map.fetch!(environment, "MN_STEP_RESULT_FILE")

      result = %{
        "outputs" => %{"value" => "shared-result"},
        "artifacts" => [],
        "metrics" => %{},
        "status" => "completed"
      }

      {:ok, reference} =
        MirrorNeuron.Artifacts.StagedArtifact.stage(result,
          kind: "worker_result",
          submission_path: submission,
          submission_id: Map.get(environment, "MN_STORAGE_SUBMISSION_ID"),
          run_id: "run-1"
        )

      File.mkdir_p!(Path.dirname(pointer))
      File.write!(pointer, Jason.encode!(%{"result_ref" => reference}))

      {:ok,
       %{
         "sandbox_name" => "shared-result-runner",
         "exit_code" => 0,
         "stdout" => "worker log only",
         "stderr" => "",
         "logs" => "worker log only"
       }}
    end
  end

  defmodule BeaconMissRunner do
    def run(_payload, _config, opts) do
      attempt = Process.get(:beacon_miss_attempt, 0) + 1
      Process.put(:beacon_miss_attempt, attempt)
      callback = Keyword.get(opts, :event_callback)

      if is_function(callback, 2) do
        callback.(:agent_beacon_missed, %{
          "agent_id" => Keyword.get(opts, :agent_id),
          "attempt" => attempt,
          "source" => "agent",
          "status" => "missed"
        })
      end

      {:error, %{"error" => "agent beacon deadline exceeded", "attempt" => attempt}}
    end
  end

  defmodule BeaconOkRunner do
    def run(_payload, _config, opts) do
      callback = Keyword.get(opts, :event_callback)

      if is_function(callback, 2) do
        callback.(:agent_beacon, %{
          "agent_id" => Keyword.get(opts, :agent_id),
          "attempt" => Keyword.get(opts, :attempt),
          "source" => "agent",
          "status" => "working",
          "message" => "still working"
        })
      end

      {:ok,
       %{
         "sandbox_name" => "beacon-ok-runner",
         "exit_code" => 0,
         "stdout" => "{}",
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule StructuredRunner do
    def run(_payload, _config, opts) do
      count = get_in(opts, [:agent_state, "count"]) || 0
      next = count + 1

      stdout =
        Jason.encode!(%{
          "next_state" => %{"count" => next},
          "events" => [%{"type" => "custom_metric", "payload" => %{"count" => next}}],
          "emit_messages" => [
            %{
              "type" => "stream_chunk",
              "body" => %{"count" => next},
              "headers" => %{"kind" => "demo"}
            }
          ],
          "complete_run" => if(next >= 2, do: %{"count" => next}, else: nil)
        })

      {:ok,
       %{
         "sandbox_name" => "structured-runner",
         "exit_code" => 0,
         "stdout" => stdout,
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule InvalidStructuredRunner do
    def run(_payload, _config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "invalid-structured-runner",
         "exit_code" => 0,
         "stdout" => "{\"emit_messages\":",
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  defmodule RetiredCompletionRunner do
    def run(_payload, _config, _opts) do
      {:ok,
       %{
         "sandbox_name" => "legacy-completion-runner",
         "exit_code" => 0,
         "stdout" => Jason.encode!(%{"complete_job" => true}),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  test "retries transient sandbox failures and emits the successful result" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "prime_worker_0001",
      config: %{
        :runner_module => FlakyRunner,
        :lease_manager => lease_manager,
        "max_attempts" => 3,
        "retry_backoff_ms" => 1,
        "output_message_type" => "prime_chunk_result"
      }
    }

    {:ok, state} = Executor.init(node)

    context = %{
      job_id: "job-1",
      node: %{node_id: "prime_worker_0001"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    {:ok, next_state, actions} =
      Executor.handle_message(message("job-1", "prime_chunk_request", %{}), state, context)

    assert Process.get(:sandbox_worker_attempt) == 2
    assert next_state.last_result["attempts"] == 2
    assert next_state.last_result["lease"]["pool"] == "default"

    assert {:emit, "prime_chunk_result", payload, _opts} =
             Enum.find(actions, &match?({:emit, _, _, _}, &1))

    assert payload["sandbox"]["attempts"] == 2
    assert payload["sandbox"]["lease"]["slots"] == 1
    refute Map.has_key?(payload, "input")

    assert_receive {:agent_event, "prime_worker_0001", :executor_lease_requested,
                    %{"pool" => "default", "slots" => 1}}

    assert_receive {:agent_event, "prime_worker_0001", :executor_lease_acquired,
                    %{"pool" => "default", "slots" => 1, "lease_id" => _lease_id}}

    assert_receive {:agent_event, "prime_worker_0001", :executor_lease_released,
                    %{"pool" => "default", "slots" => 1, "lease_id" => _lease_id}}
  end

  @tag :tmp_dir
  test "oversized fallback result is staged and never echoes executor input", %{tmp_dir: tmp_dir} do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    submission = Path.join(tmp_dir, "submission")

    node = %{
      node_id: "large_worker",
      config: %{
        :runner_module => LargeFallbackRunner,
        :lease_manager => lease_manager,
        "max_attempts" => 1,
        "output_message_type" => "large_result",
        "environment" => %{
          "MN_JOB_SHARED_STORAGE_ROOT" => submission,
          "MN_STORAGE_SUBMISSION_ID" => "submission-1"
        }
      }
    }

    {:ok, state} = Executor.init(node)
    original = %{"nested" => %{"prior" => String.duplicate("input", 10_000)}}

    context = %{
      job_id: "job-1",
      node: %{node_id: "large_worker"},
      coordinator: self(),
      workflow: %{"run_id" => "run-1"},
      bundle_root: tmp_dir,
      manifest_path: Path.join(tmp_dir, "manifest.json"),
      payloads_path: Path.join(tmp_dir, "payloads")
    }

    assert {:ok, _state, actions} =
             Executor.handle_message(message("job-1", "request", original), state, context)

    assert {:emit, "large_result", payload, _opts} =
             Enum.find(actions, &match?({:emit, _, _, _}, &1))

    reference = payload["outputs"][StagedArtifact.output_key()]
    resolved = StagedArtifact.resolve!(reference, submission_path: submission)

    refute Map.has_key?(resolved, "input")
    refute inspect(resolved) =~ String.duplicate("input", 100)
  end

  @tag :tmp_dir
  test "reads SDK structured result from shared pointer while preserving stdout logs", %{
    tmp_dir: tmp_dir
  } do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    submission = Path.join(tmp_dir, "submission")

    node = %{
      node_id: "shared_worker",
      config: %{
        :runner_module => SharedResultRunner,
        :lease_manager => lease_manager,
        "command" => ["python3", "-m", "mn_sdk.step_runtime"],
        "output_message_type" => "shared_result",
        "environment" => %{
          "MN_JOB_SHARED_STORAGE_ROOT" => submission,
          "MN_STORAGE_SUBMISSION_ID" => "submission-1"
        }
      }
    }

    {:ok, state} = Executor.init(node)

    context = %{
      job_id: "job-1",
      node: %{node_id: "shared_worker"},
      coordinator: self(),
      workflow: %{"run_id" => "run-1", "attempt_id" => "attempt-1"},
      bundle_root: tmp_dir,
      manifest_path: Path.join(tmp_dir, "manifest.json"),
      payloads_path: Path.join(tmp_dir, "payloads")
    }

    assert {:ok, _state, actions} =
             Executor.handle_message(message("job-1", "request", %{}), state, context)

    assert {:emit, "shared_result", payload, _opts} =
             Enum.find(actions, &match?({:emit, _, _, _}, &1))

    assert payload["outputs"] == %{"value" => "shared-result"}
    assert payload["status"] == "completed"
    refute Map.has_key?(payload, "sandbox")
  end

  test "does not retry non-transient sandbox failures" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "prime_worker_0002",
      config: %{
        :runner_module => HardFailRunner,
        :lease_manager => lease_manager,
        "max_attempts" => 3,
        "retry_backoff_ms" => 1
      }
    }

    {:ok, state} = Executor.init(node)

    context = %{
      job_id: "job-2",
      node: %{node_id: "prime_worker_0002"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    assert {:error, reason, failed_state} =
             Executor.handle_message(
               message("job-2", "prime_chunk_request", %{}),
               state,
               context
             )

    assert Process.get(:sandbox_worker_attempt) == 1
    assert reason["attempts"] == 1
    assert failed_state.last_error =~ "\"attempts\" => 1"

    assert_receive {:agent_event, "prime_worker_0002", :executor_lease_requested, _}
    assert_receive {:agent_event, "prime_worker_0002", :executor_lease_acquired, _}
    assert_receive {:agent_event, "prime_worker_0002", :executor_lease_released, _}
  end

  test "missed agent beacon fails the attempt and honors retry policy" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "beacon_watchdog_worker",
      config: %{
        :runner_module => BeaconMissRunner,
        :lease_manager => lease_manager,
        "max_attempts" => 2,
        "retry_backoff_ms" => 1
      }
    }

    {:ok, state} = Executor.init(node)

    context = %{
      job_id: "job-beacon-watchdog",
      node: %{node_id: "beacon_watchdog_worker"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    assert {:error, reason, failed_state} =
             Executor.handle_message(
               message("job-beacon-watchdog", "tick", %{}),
               state,
               context
             )

    assert Process.get(:beacon_miss_attempt) == 2
    assert reason["error"] == "agent beacon deadline exceeded"
    assert reason["attempts"] == 2
    assert failed_state.last_error =~ "\"attempts\" => 2"

    assert_receive {:agent_event, "beacon_watchdog_worker", :agent_beacon_missed,
                    %{"attempt" => 1, "status" => "missed"}}

    assert_receive {:agent_event, "beacon_watchdog_worker", :agent_beacon_missed,
                    %{"attempt" => 2, "status" => "missed"}}
  end

  test "successful beaconing command publishes liveness and does not retry" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "beacon_ok_worker",
      config: %{
        :runner_module => BeaconOkRunner,
        :lease_manager => lease_manager,
        "max_attempts" => 3,
        "retry_backoff_ms" => 1,
        "output_message_type" => nil
      }
    }

    {:ok, state} = Executor.init(node)

    context = %{
      job_id: "job-beacon-ok",
      node: %{node_id: "beacon_ok_worker"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    assert {:ok, next_state, actions} =
             Executor.handle_message(message("job-beacon-ok", "tick", %{}), state, context)

    assert next_state.last_result["attempts"] == 1
    assert Enum.any?(actions, &match?({:event, :sandbox_job_completed, _}, &1))

    assert_receive {:agent_event, "beacon_ok_worker", :agent_beacon,
                    %{"attempt" => 1, "status" => "working", "message" => "still working"}}

    refute_receive {:agent_event, "beacon_ok_worker", :agent_beacon_missed, _}, 20
  end

  test "accepts structured stdout actions and carries agent state forward" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "stream_worker",
      config: %{
        :runner_module => StructuredRunner,
        :lease_manager => lease_manager,
        "output_message_type" => nil
      }
    }

    {:ok, state0} = Executor.init(node)

    context = %{
      job_id: "job-structured",
      node: %{node_id: "stream_worker"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    {:ok, state1, actions1} =
      Executor.handle_message(message("job-structured", "tick", %{}), state0, context)

    assert state1.agent_state["count"] == 1
    assert Enum.any?(actions1, &match?({:event, :custom_metric, _}, &1))
    assert Enum.any?(actions1, &match?({:emit, "stream_chunk", _, _}, &1))
    refute Enum.any?(actions1, &match?({:complete_run, _}, &1))

    {:ok, state2, actions2} =
      Executor.handle_message(message("job-structured", "tick", %{}), state1, context)

    assert state2.agent_state["count"] == 2
    assert {:complete_run, %{"count" => 2}} = Enum.find(actions2, &match?({:complete_run, _}, &1))
  end

  test "retired complete_job structured stdout fails the attempt" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "retired_completion_worker",
      config: %{
        :runner_module => RetiredCompletionRunner,
        :lease_manager => lease_manager,
        "output_message_type" => nil
      }
    }

    {:ok, state0} = Executor.init(node)

    context = %{
      job_id: "job-retired-completion-output",
      node: %{node_id: "retired_completion_worker"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    assert {:error, reason, state1} =
             Executor.handle_message(
               message("job-retired-completion-output", "tick", %{}),
               state0,
               context
             )

    assert reason["error"] == "unsupported structured output key"
    assert reason["unsupported_keys"] == ["complete_job"]
    assert state1.last_error =~ "unsupported structured output key"
  end

  test "invalid structured stdout is ignored instead of crashing the workflow" do
    lease_manager =
      start_supervised!({LeaseManager, name: unique_name(), capacities: %{"default" => 1}})

    node = %{
      node_id: "invalid_output_worker",
      config: %{
        :runner_module => InvalidStructuredRunner,
        :lease_manager => lease_manager,
        "output_message_type" => nil
      }
    }

    {:ok, state0} = Executor.init(node)

    context = %{
      job_id: "job-invalid-structured-output",
      node: %{node_id: "invalid_output_worker"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    assert {:ok, state1, actions} =
             Executor.handle_message(
               message("job-invalid-structured-output", "tick", %{}),
               state0,
               context
             )

    assert state1.runs == 1
    assert state1.agent_state == %{}
    assert state1.last_result["stdout"] == "{\"emit_messages\":"

    assert actions == [
             {:event, :sandbox_job_completed,
              %{
                "attempts" => 1,
                "exit_code" => 0,
                "lease_id" => state1.last_result["lease"]["lease_id"],
                "pool" => "default",
                "sandbox_name" => "invalid-structured-runner"
              }}
           ]
  end

  defp message(job_id, type, body) do
    Message.new(job_id, "test_source", "executor", type, body)
  end

  defp unique_name do
    :"lease-manager-#{System.unique_integer([:positive])}"
  end
end
