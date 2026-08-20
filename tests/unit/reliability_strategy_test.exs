defmodule MirrorNeuron.Runtime.ReliabilityStrategyTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.ReliabilityStrategy

  setup do
    original_profiles = Application.get_env(:mirror_neuron, :execution_profiles)

    on_exit(fn ->
      if original_profiles == nil do
        Application.delete_env(:mirror_neuron, :execution_profiles)
      else
        Application.put_env(:mirror_neuron, :execution_profiles, original_profiles)
      end
    end)

    :ok
  end

  test "single-node job with omitted policy resolves to local restart" do
    reliability = ReliabilityStrategy.resolve(manifest())

    assert reliability["mode"] == "single_node"
    assert reliability["requested_recovery_policy"] == "auto"
    assert reliability["effective_recovery_policy"] == "local_restart"
    refute reliability["reliability_degraded"]
  end

  test "healthy multi-node auto job with durable bundle resolves to cluster recovery" do
    reliability =
      manifest()
      |> ReliabilityStrategy.resolve(healthy_multi_node_opts())

    assert reliability["mode"] == "multi_node"
    assert reliability["requested_recovery_policy"] == "auto"
    assert reliability["effective_recovery_policy"] == "cluster_recover"
    refute reliability["reliability_degraded"]
  end

  test "healthy multi-node auto job with shared filesystem bundle resolves to cluster recovery" do
    reliability =
      manifest()
      |> ReliabilityStrategy.resolve(
        healthy_multi_node_opts(%{
          "bundle_storage" => "shared_fs_cas",
          "bundle_fingerprint" => "sha256-test"
        })
      )

    assert reliability["mode"] == "multi_node"
    assert reliability["effective_recovery_policy"] == "cluster_recover"
    refute reliability["reliability_degraded"]
  end

  test "explicit cluster recovery on a single node starts degraded as local restart" do
    reliability = ReliabilityStrategy.resolve(manifest("cluster_recover"))

    assert reliability["mode"] == "single_node"
    assert reliability["requested_recovery_policy"] == "cluster_recover"
    assert reliability["effective_recovery_policy"] == "local_restart"
    assert reliability["reliability_degraded"]
    assert reliability["reason"] =~ "fewer than 2 healthy connected runtime nodes"
  end

  test "explicit manual recovery is never upgraded" do
    reliability =
      manifest("manual_recover")
      |> ReliabilityStrategy.resolve(healthy_multi_node_opts())

    assert reliability["mode"] == "multi_node"
    assert reliability["requested_recovery_policy"] == "manual_recover"
    assert reliability["effective_recovery_policy"] == "manual_recover"
    refute reliability["reliability_degraded"]
  end

  test "freshly observed remote nodes do not flip into multi-node before debounce" do
    now = DateTime.utc_now()
    self_node = to_string(Node.self())

    reliability =
      manifest()
      |> ReliabilityStrategy.resolve(
        manifest_ref: durable_ref(),
        now: now,
        stable_ms: 10_000,
        connected_nodes: [self_node, "fresh@127.0.0.1"],
        node_states: [
          %{
            "node" => "fresh@127.0.0.1",
            "status" => "healthy",
            "node_role" => "runtime",
            "updated_at" => DateTime.to_iso8601(now)
          }
        ]
      )

    assert reliability["mode"] == "single_node"
    assert reliability["effective_recovery_policy"] == "local_restart"
  end

  test "node add is trusted only after debounce and node remove degrades back to single node" do
    now = DateTime.utc_now()
    self_node = to_string(Node.self())
    remote = "runtime-c@127.0.0.1"

    fresh_remote = %{
      "node" => remote,
      "status" => "healthy",
      "node_role" => "runtime",
      "updated_at" => DateTime.to_iso8601(now)
    }

    stable_remote = %{
      fresh_remote
      | "updated_at" => DateTime.add(now, -20, :second) |> DateTime.to_iso8601()
    }

    added_too_recently =
      ReliabilityStrategy.resolve(
        manifest(),
        manifest_ref: durable_ref(),
        now: now,
        stable_ms: 10_000,
        connected_nodes: [self_node, remote],
        node_states: [fresh_remote]
      )

    added_after_debounce =
      ReliabilityStrategy.resolve(
        manifest(),
        manifest_ref: durable_ref(),
        now: now,
        stable_ms: 10_000,
        connected_nodes: [self_node, remote],
        node_states: [stable_remote]
      )

    removed_or_disconnected =
      ReliabilityStrategy.resolve(
        manifest(),
        manifest_ref: durable_ref(),
        now: now,
        stable_ms: 10_000,
        connected_nodes: [self_node],
        node_states: [stable_remote]
      )

    assert added_too_recently["mode"] == "single_node"
    assert added_after_debounce["mode"] == "multi_node"
    assert added_after_debounce["effective_recovery_policy"] == "cluster_recover"
    assert removed_or_disconnected["mode"] == "single_node"
    assert removed_or_disconnected["effective_recovery_policy"] == "local_restart"
  end

  test "configured but disconnected or control nodes do not count toward multi-node recovery" do
    self_node = to_string(Node.self())

    disconnected_runtime = %{
      "node" => "configured-only@127.0.0.1",
      "status" => "healthy",
      "node_role" => "runtime"
    }

    connected_control = %{
      "node" => "control@127.0.0.1",
      "status" => "healthy",
      "node_role" => "control"
    }

    disconnected_result =
      ReliabilityStrategy.resolve(
        manifest(),
        manifest_ref: durable_ref(),
        stable_ms: 0,
        connected_nodes: [self_node],
        node_states: [disconnected_runtime]
      )

    control_result =
      ReliabilityStrategy.resolve(
        manifest(),
        manifest_ref: durable_ref(),
        stable_ms: 0,
        connected_nodes: [self_node, connected_control["node"]],
        node_states: [connected_control]
      )

    assert disconnected_result["mode"] == "single_node"
    assert control_result["mode"] == "single_node"
  end

  test "profile-heavy jobs require another healthy node with the same profile" do
    Application.put_env(:mirror_neuron, :execution_profiles, %{
      "opencv-video-guardian" => %{"gpu" => true}
    })

    manifest = manifest("auto", %{"execution_profile" => "opencv-video-guardian"})

    without_profile =
      ReliabilityStrategy.resolve(
        manifest,
        healthy_multi_node_opts(%{
          "node" => "general@127.0.0.1",
          "status" => "healthy",
          "node_role" => "runtime",
          "profiles" => [],
          "gpu" => true
        })
      )

    with_profile =
      ReliabilityStrategy.resolve(
        manifest,
        healthy_multi_node_opts(%{
          "node" => "video@127.0.0.1",
          "status" => "healthy",
          "node_role" => "runtime",
          "profiles" => ["opencv-video-guardian"],
          "gpu" => true
        })
      )

    assert without_profile["effective_recovery_policy"] == "local_restart"
    assert without_profile["reason"] =~ "opencv-video-guardian"
    assert with_profile["effective_recovery_policy"] == "cluster_recover"
  end

  defp manifest(policy \\ nil, config \\ %{}) do
    policies =
      case policy do
        nil -> %{}
        value -> %{"recovery_mode" => value}
      end

    {:ok, manifest} =
      Manifest.load(%{
        "apiVersion" => "mn.workflow/v1",
        "manifest_version" => "1.0",
        "graph_id" => "adaptive-reliability-test",
        "entrypoints" => ["worker"],
        "flow" => %{
          "nodes" => [
            %{
              "node_id" => "worker",
              "agent_type" => "executor",
              "role" => "root_coordinator",
              "config" => config
            }
          ],
          "edges" => []
        },
        "policies" => policies
      })

    manifest
  end

  defp healthy_multi_node_opts(manifest_ref_or_remote_state \\ nil)

  defp healthy_multi_node_opts(%{"bundle_storage" => _storage} = manifest_ref) do
    healthy_multi_node_opts(nil)
    |> Keyword.put(:manifest_ref, manifest_ref)
  end

  defp healthy_multi_node_opts(remote_state) do
    self_node = to_string(Node.self())

    remote_state =
      remote_state ||
        %{
          "node" => "runtime-b@127.0.0.1",
          "status" => "healthy",
          "node_role" => "runtime"
        }

    [
      manifest_ref: durable_ref(),
      stable_ms: 0,
      connected_nodes: [self_node, remote_state["node"]],
      node_states: [remote_state]
    ]
  end

  defp durable_ref do
    %{"bundle_storage" => "redis", "bundle_fingerprint" => "sha256-test"}
  end
end
