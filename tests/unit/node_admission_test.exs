defmodule MirrorNeuron.Runtime.NodeAdmissionTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runtime.{NodeAdmission, NodeAdmissionState}

  defmodule Node do
    def self, do: Process.get(:admission_node, :spark@test)
  end

  defmodule UnavailableStore do
    def fetch_node_admission(_node), do: {:error, :unavailable}
  end

  defmodule Store do
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{states: %{}, schedules: %{}} end, name: __MODULE__)

    def fetch_node_admission(node),
      do: {:ok, Agent.get(__MODULE__, &Map.get(&1.states, node, NodeAdmissionState.new()))}

    def compare_node_admission(node, expected, next) do
      Agent.get_and_update(__MODULE__, fn data ->
        current = Map.get(data.states, node, NodeAdmissionState.new())

        if current["version"] == expected,
          do: {:ok, put_in(data, [:states, node], next)},
          else: {{:error, :admission_conflict}, data}
      end)
    end

    def list_jobs, do: {:ok, []}
    def fetch_job(_), do: {:error, :not_found}

    def coordination_store_status,
      do: {:ok, %{"identity" => "test-store", "healthy" => true, "writable_primary" => true}}

    def fetch_schedule(id) do
      case Agent.get(__MODULE__, & &1.schedules[id]) do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end

    def persist_schedule(id, schedule) do
      Agent.update(__MODULE__, &put_in(&1, [:schedules, id], schedule))
      {:ok, schedule}
    end

    def roundtrip do
      Agent.update(__MODULE__, fn data ->
        %{data | states: data.states |> Jason.encode!() |> Jason.decode!()}
      end)
    end
  end

  setup do
    start_supervised!(Store)
    keys = [:node_admission_store, :cluster_node_adapter, :coordination_store]
    before = Map.new(keys, &{&1, Application.get_env(:mirror_neuron, &1)})
    Application.put_env(:mirror_neuron, :node_admission_store, Store)
    Application.put_env(:mirror_neuron, :cluster_node_adapter, Node)
    Application.put_env(:mirror_neuron, :coordination_store, Store)

    on_exit(fn ->
      Enum.each(before, fn {key, value} ->
        if value,
          do: Application.put_env(:mirror_neuron, key, value),
          else: Application.delete_env(:mirror_neuron, key)
      end)
    end)
  end

  defp job(id),
    do: %{
      "job_id" => id,
      "stable_job_id" => "job-" <> id,
      "job_name" => id,
      "submitted_at" => "2026-10-19T12:00:00Z"
    }

  test "credential rotation revokes waiting authorization without storing credentials" do
    previous = System.get_env("MN_GRPC_AUTH_TOKEN")

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_GRPC_AUTH_TOKEN", previous),
        else: System.delete_env("MN_GRPC_AUTH_TOKEN")
    end)

    System.put_env("MN_GRPC_AUTH_TOKEN", "admission-test-original")
    epoch = NodeAdmission.authority_epoch()
    refute epoch =~ "admission-test-original"
    assert NodeAdmission.authorized?(epoch)
    System.put_env("MN_GRPC_AUTH_TOKEN", "admission-test-revoked")
    refute NodeAdmission.authorized?(epoch)
  end

  test "protected starts require the native owner's exclusive-run capability" do
    alias MirrorNeuron.Cluster.Hardware
    on_exit(fn -> Hardware.clear_snapshot() end)
    Hardware.update_snapshot(%{capabilities: ["exclusive_run_v1"]})
    assert {:error, message} = NodeAdmission.ensure_supported()
    assert message =~ "native runtime"
    Hardware.update_snapshot(%{native_sdk_grpc: %{capabilities: ["exclusive_run_v1"]}})
    assert :ok = NodeAdmission.ensure_supported()
  end

  test "federation advertises the current holder and FIFO without private request claims" do
    alias MirrorNeuron.Grpc.Handlers.ClusterHandshake

    missing_config =
      Enum.filter(
        [runtime_shared_storage_root: System.tmp_dir!()] ++ MirrorNeuron.Config.app_env!(),
        fn {key, _} ->
          Application.fetch_env(:mirror_neuron, key) == :error
        end
      )

    Application.put_all_env(mirror_neuron: missing_config)

    on_exit(fn ->
      Enum.each(missing_config, fn {key, _} -> Application.delete_env(:mirror_neuron, key) end)
    end)

    {:ok, _} = NodeAdmission.submit(job("research"))
    {:ok, _} = NodeAdmission.submit(job("litigation"))
    token = String.duplicate("a", 32)

    assert {:ok, _} =
             NodeAdmission.command(%{
               "operation" => "node_admission",
               "action" => "request_acquire",
               "run_id" => "research",
               "generation" => 1,
               "token" => token
             })

    admission = ClusterHandshake.node_advertisement_info()["admission"]
    assert admission["capability"] == "exclusive_run_v1"
    assert admission["holder"]["run_id"] == "research"
    assert Enum.map(admission["queue"], & &1["run_id"]) == ["litigation"]
    assert admission["generation"] == 1
    assert admission["legacy"] == []
    refute Map.has_key?(admission, "requests")
    refute Jason.encode!(admission) =~ token

    assert {:ok, _} =
             NodeAdmission.command(%{
               "operation" => "node_admission",
               "action" => "request_release",
               "token" => token
             })

    assert :ok = NodeAdmission.retire("research")
    {:ok, _} = NodeAdmission.submit(job("next"))
    refreshed = ClusterHandshake.node_advertisement_info()["admission"]
    assert refreshed["holder"]["run_id"] == "litigation"
    assert refreshed["generation"] == 2

    Application.put_env(:mirror_neuron, :node_admission_store, UnavailableStore)

    assert ClusterHandshake.node_advertisement_info()["admission"] == %{
             "capability" => "exclusive_run_v1",
             "state" => "unavailable"
           }
  end

  test "concurrent starts from clients produce one holder and unique durable queue entries" do
    receipts =
      1..20
      |> Task.async_stream(fn n -> NodeAdmission.submit(job("run-#{n}")) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert Enum.count(receipts, &(&1["state"] == "preparing")) == 1
    {:ok, state} = NodeAdmission.snapshot()
    assert length(state["queue"]) == 19
    assert length(Enum.uniq(Enum.map(state["queue"], & &1["run_id"]))) == 19
    id = state["holder"]["run_id"]
    assert {:ok, %{"state" => "preparing"}} = NodeAdmission.submit(job(id))
    Store.roundtrip()
    assert {:ok, ^state} = NodeAdmission.snapshot()
  end

  test "A and B on Spark, C on another PC, and B becomes the sole holder after A drains" do
    {:ok, _} = NodeAdmission.submit(job("a"))
    {:ok, receipt} = NodeAdmission.submit(job("b"))
    assert receipt["position"] == 1
    assert receipt["owner_node"] == "spark@test"
    Process.put(:admission_node, :other@test)
    assert {:ok, %{"state" => "preparing"}} = NodeAdmission.submit(job("c"))
    Process.put(:admission_node, :spark@test)
    token = String.duplicate("a", 32)

    assert {:ok, _} =
             NodeAdmission.command(%{
               "operation" => "node_admission",
               "action" => "request_acquire",
               "run_id" => "a",
               "generation" => 1,
               "token" => token
             })

    assert {:error, :node_requests_active} = NodeAdmission.retire("a")

    assert {:error, :node_reserved} =
             NodeAdmission.command(%{
               "operation" => "node_admission",
               "action" => "request_acquire",
               "run_id" => "b",
               "token" => String.duplicate("b", 32)
             })

    assert {:ok, _} =
             NodeAdmission.command(%{
               "operation" => "node_admission",
               "action" => "request_release",
               "token" => token
             })

    assert :ok = NodeAdmission.retire("a")
    {:ok, next} = NodeAdmission.submit(job("d"))
    assert next["position"] == 1
    {:ok, state} = NodeAdmission.snapshot()
    assert state["holder"]["run_id"] == "b"

    assert NodeAdmission.run(
             %{"node_admission_owner" => "spark@test", "node_admission_generation" => 1},
             "b",
             fn -> :started end
           ) == {:error, "This PC is not reserved for this run."}

    assert NodeAdmission.run(
             %{"node_admission_owner" => "spark@test", "node_admission_generation" => 2},
             "b",
             fn -> :started end
           ) == :started

    Process.put(:admission_node, :other@test)
    assert {:ok, %{"holder" => %{"run_id" => "c"}}} = NodeAdmission.snapshot()
  end
end
