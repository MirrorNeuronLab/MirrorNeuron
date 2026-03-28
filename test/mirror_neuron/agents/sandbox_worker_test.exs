defmodule MirrorNeuron.ExecutorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Executor
  alias MirrorNeuron.Execution.LeaseManager

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
      {:error, %{"error" => "missing script", "logs" => "python3: can't open file"}}
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
          "complete_job" => if(next >= 2, do: %{"count" => next}, else: nil)
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
      Executor.handle_message(%{type: "prime_chunk_request", payload: %{}}, state, context)

    assert Process.get(:sandbox_worker_attempt) == 2
    assert next_state.last_result["attempts"] == 2
    assert next_state.last_result["lease"]["pool"] == "default"

    assert {:emit, "prime_chunk_result", payload, _opts} =
             Enum.find(actions, &match?({:emit, _, _, _}, &1))

    assert payload["sandbox"]["attempts"] == 2
    assert payload["sandbox"]["lease"]["slots"] == 1

    assert_receive {:agent_event, "prime_worker_0001", :executor_lease_requested,
                    %{"pool" => "default", "slots" => 1}}

    assert_receive {:agent_event, "prime_worker_0001", :executor_lease_acquired,
                    %{"pool" => "default", "slots" => 1, "lease_id" => _lease_id}}

    assert_receive {:agent_event, "prime_worker_0001", :executor_lease_released,
                    %{"pool" => "default", "slots" => 1, "lease_id" => _lease_id}}
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
               %{type: "prime_chunk_request", payload: %{}},
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
      Executor.handle_message(%{type: "tick", payload: %{}}, state0, context)

    assert state1.agent_state["count"] == 1
    assert Enum.any?(actions1, &match?({:event, :custom_metric, _}, &1))
    assert Enum.any?(actions1, &match?({:emit, "stream_chunk", _, _}, &1))
    refute Enum.any?(actions1, &match?({:complete_job, _}, &1))

    {:ok, state2, actions2} =
      Executor.handle_message(%{type: "tick", payload: %{}}, state1, context)

    assert state2.agent_state["count"] == 2
    assert {:complete_job, %{"count" => 2}} = Enum.find(actions2, &match?({:complete_job, _}, &1))
  end

  defp unique_name do
    :"lease-manager-#{System.unique_integer([:positive])}"
  end
end
