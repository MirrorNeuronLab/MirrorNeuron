defmodule MirrorNeuron.ResourceTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Resource

  defmodule Store do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)
    def fetch_resource_limits, do: Agent.get(__MODULE__, &fetch/1)

    def persist_resource_limits(limits),
      do: Agent.get_and_update(__MODULE__, &persist(&1, limits))

    defp fetch(nil), do: {:error, "not found"}
    defp fetch(limits), do: {:ok, limits}

    defp persist(_current, limits), do: {{:ok, limits}, limits}
  end

  defmodule Nodes do
    def resource_nodes do
      [
        %{
          "name" => "mn1@127.0.0.1",
          "status" => "draining",
          "scheduling_eligible" => false,
          "drain" => %{"status" => "blocked_no_placement", "reason" => "kernel update"},
          "hardware" => %{
            "cpu" => %{"logical_processors" => 8},
            "memory" => %{"total_bytes" => 16 * 1024 * 1024 * 1024},
            "disk" => %{
              "total_bytes" => 100 * 1024 * 1024 * 1024,
              "available_bytes" => 80 * 1024 * 1024 * 1024
            },
            "gpu" => [%{"name" => "GPU 1"}, %{"name" => "GPU 2"}]
          }
        },
        %{
          "name" => "mn2@127.0.0.1",
          "hardware" => %{
            "cpu" => %{"logical_processors" => 4},
            "memory" => %{"total_mb" => 8192},
            "disk" => %{"total_mb" => 50 * 1024, "available_mb" => 30 * 1024},
            "gpu" => "Unknown or None"
          }
        }
      ]
    end
  end

  defmodule SingleNode do
    def resource_nodes do
      [
        %{
          "name" => "mn1@127.0.0.1",
          "hardware" => %{
            "cpu" => %{"logical_processors" => 8},
            "memory" => %{"total_bytes" => 16 * 1024 * 1024 * 1024},
            "disk" => %{
              "total_bytes" => 100 * 1024 * 1024 * 1024,
              "available_bytes" => 80 * 1024 * 1024 * 1024
            },
            "gpu" => [%{"name" => "GPU 1"}]
          }
        }
      ]
    end
  end

  setup do
    {:ok, _pid} = start_supervised(Store)
    Application.put_env(:mirror_neuron, :resource_limits_store, Store)
    Application.put_env(:mirror_neuron, :resource_nodes_provider, Nodes)

    on_exit(fn ->
      Application.delete_env(:mirror_neuron, :resource_limits_store)
      Application.delete_env(:mirror_neuron, :resource_nodes_provider)
    end)

    :ok
  end

  test "lists cluster resource totals with default limits" do
    report = Resource.list()

    assert report["mode"] == "cluster"
    assert report["node_count"] == 2

    assert report["totals"] == %{
             "cpu_cores" => 12,
             "gpu_count" => 2,
             "memory_gb" => 24.0,
             "disk_gb" => 150.0,
             "disk_available_gb" => 110.0
           }

    assert report["combined"] == report["totals"]
    assert report["limits"] == %{"cpu" => 100, "gpu" => 100, "memory" => 100, "disk" => 100}

    assert report["usable"] == %{
             "cpu_cores" => 12,
             "gpu_count" => 2,
             "memory_gb" => 24.0,
             "disk_gb" => 150.0,
             "disk_available_gb" => 110.0
           }
  end

  test "lists node scheduling and drain metadata with resource totals" do
    report = Resource.list()

    [draining | _] = report["nodes"]
    assert draining["name"] == "mn1@127.0.0.1"
    assert draining["status"] == "draining"
    assert draining["scheduling_eligible"] == false
    assert draining["drain"] == %{"status" => "blocked_no_placement", "reason" => "kernel update"}
  end

  test "keeps single-node resources while exposing combined totals" do
    Application.put_env(:mirror_neuron, :resource_nodes_provider, SingleNode)

    report = Resource.list()

    assert report["mode"] == "single_node"
    assert report["node_count"] == 1
    assert [%{"name" => "mn1@127.0.0.1", "cpu_cores" => 8, "gpu_count" => 1}] = report["nodes"]

    assert report["combined"] == %{
             "cpu_cores" => 8,
             "gpu_count" => 1,
             "memory_gb" => 16.0,
             "disk_gb" => 100.0,
             "disk_available_gb" => 80.0
           }
  end

  test "sets allowed percentages and applies usable totals" do
    assert {:ok, report} =
             Resource.set(%{"cpu" => 50, "gpu" => 25, "memory" => "75", "disk" => 50})

    assert report["limits"] == %{"cpu" => 50, "gpu" => 25, "memory" => 75, "disk" => 50}
    assert report["combined"] == report["totals"]

    assert report["usable"] == %{
             "cpu_cores" => 6,
             "gpu_count" => 0,
             "memory_gb" => 18.0,
             "disk_gb" => 75.0,
             "disk_available_gb" => 55.0
           }

    assert Resource.limit_ratio(:memory) == 0.75
  end

  test "rejects unsupported percentages" do
    assert {:error, "cpu must be one of 25, 50, 75, 100"} = Resource.set(%{"cpu" => 60})
  end
end
