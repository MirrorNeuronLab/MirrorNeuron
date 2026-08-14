defmodule MirrorNeuron.Runtime.LifecyclePolicyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.LifecyclePolicy

  test "normalizes service cluster recovery defaults" do
    {:ok, manifest} = Manifest.load(manifest())

    policy = LifecyclePolicy.restart_policy(manifest, "service", "cluster_recover")
    assert policy["attempts"] == 3
    assert policy["interval_ms"] == 600_000
    assert policy["delay_function"] == "exponential"
    assert policy["delay_ms"] == 1_000
    assert policy["max_delay_ms"] == 30_000
    assert policy["mode"] == "fail"

    reschedule = LifecyclePolicy.reschedule_policy(manifest, "service", "cluster_recover")
    assert reschedule["unlimited"] == true
    assert reschedule["delay_function"] == "exponential"
    assert reschedule["max_delay_ms"] == 300_000
  end

  test "local service defaults delay instead of failing after the restart window" do
    {:ok, manifest} = Manifest.load(manifest())

    policy = LifecyclePolicy.restart_policy(manifest, "service", "local_restart")

    assert policy["mode"] == "delay"
  end

  test "batch defaults are bounded and reschedule once" do
    {:ok, manifest} = Manifest.load(manifest())

    restart = LifecyclePolicy.restart_policy(manifest, "batch", "cluster_recover")
    reschedule = LifecyclePolicy.reschedule_policy(manifest, "batch", "cluster_recover")

    assert restart["attempts"] == 3
    assert restart["interval_ms"] == 86_400_000
    assert restart["mode"] == "fail"
    assert reschedule["attempts"] == 1
    assert reschedule["unlimited"] == false
    assert reschedule["delay_function"] == "constant"
  end

  test "manual recover disables automatic restart and reschedule" do
    {:ok, manifest} = Manifest.load(manifest())

    restart = LifecyclePolicy.restart_policy(manifest, "service", "manual_recover")
    reschedule = LifecyclePolicy.reschedule_policy(manifest, "service", "manual_recover")

    assert restart["enabled"] == false
    assert reschedule["enabled"] == false
  end

  test "legacy max_agent_restart_attempts is a fallback when restart attempts are absent" do
    {:ok, manifest} =
      manifest(%{
        "policies" => %{
          "recovery_mode" => "local_restart",
          "max_agent_restart_attempts" => 7
        }
      })
      |> Manifest.load()

    assert LifecyclePolicy.restart_policy(manifest, "batch", "local_restart")["attempts"] == 7
  end

  test "explicit restart attempts override legacy max_agent_restart_attempts" do
    {:ok, manifest} =
      manifest(%{
        "policies" => %{
          "recovery_mode" => "local_restart",
          "max_agent_restart_attempts" => 7,
          "restart" => %{"attempts" => 2}
        }
      })
      |> Manifest.load()

    assert LifecyclePolicy.restart_policy(manifest, "batch", "local_restart")["attempts"] == 2
  end

  test "per-agent policy overrides job-level policy" do
    {:ok, manifest} =
      manifest(%{
        "policies" => %{
          "recovery_mode" => "local_restart",
          "restart" => %{"attempts" => 5}
        },
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "policies" => %{"restart" => %{"attempts" => 1, "delay_ms" => 25}}
          }
        ]
      })
      |> Manifest.load()

    policy = LifecyclePolicy.restart_policy(manifest, "batch", "local_restart", "worker")
    assert policy["attempts"] == 1
    assert policy["delay_ms"] == 25
  end

  test "attempt decisions use sliding windows and delay functions" do
    policy = %{
      "type" => "restart",
      "enabled" => true,
      "attempts" => 2,
      "interval_ms" => 1_000,
      "delay_ms" => 10,
      "delay_function" => "exponential",
      "max_delay_ms" => 50,
      "mode" => "fail"
    }

    now = ~U[2026-05-24 10:00:00.000Z]

    history = [
      %{"at" => DateTime.add(now, -100, :millisecond) |> DateTime.to_iso8601()},
      %{"at" => DateTime.add(now, -200, :millisecond) |> DateTime.to_iso8601()}
    ]

    assert {:exhausted, exhausted} = LifecyclePolicy.attempt_decision(policy, history, now)
    assert exhausted["wait_until"]

    old_history = [
      %{"at" => DateTime.add(now, -2_000, :millisecond) |> DateTime.to_iso8601()}
    ]

    assert {:allowed, decision} = LifecyclePolicy.attempt_decision(policy, old_history, now)
    assert decision["attempt"] == 1
    assert decision["delay_ms"] == 10

    assert LifecyclePolicy.delay_ms(policy, 4) == 50
  end

  test "fibonacci delay is capped" do
    policy = %{
      "delay_ms" => 10,
      "delay_function" => "fibonacci",
      "max_delay_ms" => 30
    }

    assert LifecyclePolicy.delay_ms(policy, 1) == 10
    assert LifecyclePolicy.delay_ms(policy, 4) == 30
  end

  defp manifest(overrides \\ %{}) do
    %{
      "apiVersion" => "mn.workflow/v2",
      "manifest_version" => "1.0",
      "graph_id" => "policy-test",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root"
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }
    |> Map.merge(overrides)
    |> flow_manifest()
  end

  defp flow_manifest(manifest) do
    {nodes, manifest} = Map.pop(manifest, "nodes")
    {edges, manifest} = Map.pop(manifest, "edges")

    flow =
      manifest
      |> Map.get("flow", %{})
      |> maybe_put_topology("nodes", nodes)
      |> maybe_put_topology("edges", edges)

    Map.put(manifest, "flow", flow)
  end

  defp maybe_put_topology(flow, _key, nil), do: flow
  defp maybe_put_topology(flow, key, value), do: Map.put(flow, key, value)
end
