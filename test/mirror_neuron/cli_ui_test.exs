defmodule MirrorNeuron.CLI.UITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MirrorNeuron.CLI.UI

  test "renders a banner with branding and subtitle" do
    output =
      capture_io(fn ->
        UI.puts(UI.banner(:run, "examples/research_flow"))
      end)

    assert output =~ "MirrorNeuron CLI"
    assert output =~ "examples/research_flow"
    assert output =~ "Event-driven runtime for sandboxed agents"
  end

  test "renders a progress panel with the main runtime metrics" do
    output =
      capture_io(fn ->
        UI.puts(
          UI.progress_panel(
            "job-123",
            %{"status" => "running"},
            %{
              collected: 2,
              expected_results: 6,
              sandbox_done: 1,
              sandbox_total: 3,
              leases_running: 1,
              leases_waiting: 2,
              total_events: 14,
              last_event: %{"type" => "sandbox_job_completed", "agent_id" => "worker_2"}
            },
            System.monotonic_time(:millisecond) - 1_200,
            1
          )
        )
      end)

    assert output =~ "Runtime Progress"
    assert output =~ "job-123"
    assert output =~ "Results:"
    assert output =~ "Sandboxes:"
    assert output =~ "Leases:"
    assert output =~ "sandbox_job_completed(worker_2)"
  end

  test "renders a compact cluster nodes table" do
    output =
      capture_io(fn ->
        UI.puts(
          UI.nodes_table([
            %{
              name: "mn1@192.168.4.29",
              self?: true,
              connected_nodes: ["mn1@192.168.4.29", "mn2@192.168.4.35"],
              scheduler_hint: "cluster_member",
              executor_pools: %{"default" => %{available: 2, capacity: 4, queued: 1}}
            },
            %{
              name: "mn2@192.168.4.35",
              self?: false,
              connected_nodes: ["mn1@192.168.4.29", "mn2@192.168.4.35"],
              scheduler_hint: "remote_member",
              executor_pools: %{"default" => %{available: 1, capacity: 4, queued: 0}}
            }
          ])
        )
      end)

    assert output =~ "Cluster Nodes"
    assert output =~ "mn1@192.168.4.29"
    assert output =~ "mn2@192.168.4.35"
    assert output =~ "2/4 free q=1"
    assert output =~ "remote_member"
  end

  test "renders an agents table with placement details" do
    output =
      capture_io(fn ->
        UI.puts(
          UI.agents_table([
            %{
              "agent_id" => "prime_worker_0001",
              "agent_type" => "executor",
              "assigned_node" => "mn1@192.168.4.29",
              "processed_messages" => 3,
              "mailbox_depth" => 0
            }
          ])
        )
      end)

    assert output =~ "Agents"
    assert output =~ "prime_worker_0001"
    assert output =~ "executor"
    assert output =~ "mn1@192.168.4.29"
  end
end
