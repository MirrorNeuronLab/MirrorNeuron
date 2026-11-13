defmodule MirrorNeuron.ReconciliationCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.ReconciliationCase
    end
  end

  @test_pid_name :reconciler_test_pid

  defmodule RedisStoreStub do
    def put_jobs(jobs), do: :persistent_term.put({__MODULE__, :jobs}, jobs)

    def put_agents(job_id, agents),
      do: :persistent_term.put({__MODULE__, :agents, job_id}, agents)

    def put_lease(job_id, lease), do: :persistent_term.put({__MODULE__, :lease, job_id}, lease)
    def clear_lease(job_id), do: :persistent_term.erase({__MODULE__, :lease, job_id})
    def raise_on_lease(job_id), do: :persistent_term.put({__MODULE__, :raise_lease, job_id}, true)

    def clear_raise_on_lease(job_id),
      do: :persistent_term.erase({__MODULE__, :raise_lease, job_id})

    def raise_on_fetch(job_id), do: :persistent_term.put({__MODULE__, :raise_fetch, job_id}, true)

    def clear_raise_on_fetch(job_id),
      do: :persistent_term.erase({__MODULE__, :raise_fetch, job_id})

    def put_evals(evals),
      do: :persistent_term.put({__MODULE__, :evals}, Map.new(evals, &{&1["eval_id"], &1}))

    def list_jobs, do: {:ok, :persistent_term.get({__MODULE__, :jobs}, [])}

    def list_job_summaries do
      jobs =
        :persistent_term.get({__MODULE__, :jobs}, [])
        |> Enum.map(fn job ->
          job
          |> Map.take([
            "job_id",
            "status",
            "job_type",
            "scheduler",
            "lease_owner",
            "lease",
            "updated_at",
            "submitted_at",
            "recovery_policy",
            "requested_recovery_policy",
            "restart_policy",
            "reschedule_policy",
            "policy_state",
            "recovery_status",
            "recovery_requires_review",
            "recovery_reason"
          ])
          |> Map.update("scheduler", nil, &scheduler_summary/1)
        end)

      {:ok, jobs}
    end

    defp scheduler_summary(%{"placements" => placements} = scheduler) do
      scheduler
      |> Map.take(["status", "job_type", "strategy", "mode", "placement_count"])
      |> Map.put(
        "nodes",
        placements
        |> Enum.map(&Map.get(&1, "node"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
      )
    end

    defp scheduler_summary(_scheduler), do: nil

    def fetch_job(job_id) do
      if :persistent_term.get({__MODULE__, :raise_fetch, job_id}, false) do
        raise "fetch backend exploded for #{job_id}"
      end

      case Enum.find(
             :persistent_term.get({__MODULE__, :jobs}, []),
             &(Map.get(&1, "job_id") == job_id)
           ) do
        nil -> {:error, "job #{job_id} was not found"}
        job -> {:ok, job}
      end
    end

    def list_agents(job_id), do: {:ok, :persistent_term.get({__MODULE__, :agents, job_id}, [])}

    def get_lease("job:" <> job_id) do
      if :persistent_term.get({__MODULE__, :raise_lease, job_id}, false) do
        raise "lease backend exploded for #{job_id}"
      end

      {:ok, :persistent_term.get({__MODULE__, :lease, job_id}, nil)}
    end

    def persist_recovery_eval(eval_id, eval) do
      eval =
        eval
        |> Map.drop(["job", :job])
        |> Map.put("eval_id", eval_id)

      evals = :persistent_term.get({__MODULE__, :evals}, %{})
      :persistent_term.put({__MODULE__, :evals}, Map.put(evals, eval_id, eval))
      send(Process.whereis(:reconciler_test_pid), {:eval_persisted, eval_id, eval})
      {:ok, eval}
    end

    def update_recovery_eval(eval_id, updates) do
      evals = :persistent_term.get({__MODULE__, :evals}, %{})
      eval = evals |> Map.get(eval_id, %{"eval_id" => eval_id}) |> Map.merge(updates)
      persist_recovery_eval(eval_id, eval)
    end

    def list_recovery_evals do
      {:ok, :persistent_term.get({__MODULE__, :evals}, %{}) |> Map.values()}
    end

    def list_recovery_evals(statuses) do
      statuses = MapSet.new(Enum.map(List.wrap(statuses), &to_string/1))

      evals =
        :persistent_term.get({__MODULE__, :evals}, %{})
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, "status") in statuses))

      {:ok, evals}
    end

    def persist_terminal_job(job_id, updates, defaults) do
      send(Process.whereis(:reconciler_test_pid), {:job_persisted, job_id, updates, defaults})
      {:ok, defaults |> Map.merge(updates) |> Map.put("job_id", job_id)}
    end

    def release_fenced_lease(lease_name, owner, epoch) do
      send(Process.whereis(:reconciler_test_pid), {:lease_released, lease_name, owner, epoch})
      :ok
    end
  end

  defmodule ResourceStore do
    def fetch_resource_limits, do: {:error, "not configured"}
  end

  defmodule EventBusStub do
    def publish(job_id, event) do
      send(Process.whereis(:reconciler_test_pid), {:event_published, job_id, event})
      {:ok, event}
    end
  end

  defmodule CoordinatorStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:reschedule_agents, agent_ids, scheduler_plan, reason}, _from, parent) do
      send(parent, {:coordinator_rescheduled, agent_ids, scheduler_plan, reason})
      {:reply, {:ok, %{affected_agents: agent_ids, scheduler: scheduler_plan}}, parent}
    end
  end

  setup do
    previous_store = Application.get_env(:mirror_neuron, :resource_limits_store)
    Application.put_env(:mirror_neuron, :resource_limits_store, ResourceStore)

    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)
    RedisStoreStub.put_jobs([])
    RedisStoreStub.put_evals([])

    on_exit(fn ->
      if is_nil(previous_store) do
        Application.delete_env(:mirror_neuron, :resource_limits_store)
      else
        Application.put_env(:mirror_neuron, :resource_limits_store, previous_store)
      end

      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      :persistent_term.erase({RedisStoreStub, :jobs})
      :persistent_term.erase({RedisStoreStub, :evals})
    end)

    :ok
  end

  def running_job(job_id) do
    %{
      "job_id" => job_id,
      "graph_id" => "reconcile-test",
      "job_name" => "reconcile-test",
      "status" => "running",
      "lease_owner" => "coordinator@lab",
      "recovery_policy" => "cluster_recover",
      "requested_recovery_policy" => "cluster_recover",
      "manifest_ref" => %{"bundle_storage" => "redis", "bundle_fingerprint" => "test"},
      "scheduler" => %{
        "job_type" => "service",
        "strategy" => "binpack",
        "placements" => [
          %{
            "agent_id" => "worker",
            "agent_type" => "executor",
            "node" => "small@lab",
            "resources" => %{
              "cpu_cores" => 1,
              "memory_mb" => 512,
              "disk_mb" => 0,
              "gpu_count" => 0
            }
          }
        ]
      }
    }
  end

  def job_starter(parent) do
    fn job_id, _bundle, opts ->
      send(parent, {:job_started, job_id, opts})
      :ok
    end
  end

  def unique_job_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def agent_snapshot(agent_id) do
    %{
      "agent_id" => agent_id,
      "node_id" => agent_id,
      "agent_type" => "executor",
      "mailbox_depth" => 0,
      "processed_messages" => 0,
      "pending_messages" => [],
      "metadata" => %{}
    }
  end

  def shared_bundle_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "mn-reconciler-shared-cas-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "payloads"))
    File.write!(Path.join(root, "manifest.json"), Jason.encode!(manifest()))

    on_exit(fn -> File.rm_rf(root) end)

    root
  end

  def manifest do
    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "reconcile-test",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
            "config" => %{"safe_to_retry" => true}
          }
        ],
        "edges" => []
      },
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }
  end

  def gpu_manifest do
    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "gpu-reconcile-test",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "cpu_cores" => 1,
              "memory_mb" => 512,
              "devices" => [%{"kind" => "gpu", "driver" => "cuda", "count" => 1}]
            },
            "config" => %{"safe_to_retry" => true}
          }
        ],
        "edges" => []
      },
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }
  end

  def small_node do
    %{
      "name" => "small@lab",
      "status" => "healthy",
      "hardware" => %{
        "cpu" => %{"logical_processors" => 4},
        "memory" => %{"available_mb" => 4096},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  def large_node do
    %{
      "name" => "large@lab",
      "status" => "healthy",
      "hardware" => %{
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  def gpu_rejoin_node(name) do
    %{
      "name" => name,
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [
          %{
            "id" => "cuda-0",
            "index" => 0,
            "name" => "NVIDIA RTX 4090",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 24_576,
            "memory_free_mb" => 20_000,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          }
        ]
      }
    }
  end

  def future_iso(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end
end
