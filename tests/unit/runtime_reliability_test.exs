defmodule MirrorNeuron.RuntimeReliabilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MirrorNeuron.Runtime

  @runtime_envs [
    "MN_JOB_CALL_TIMEOUT_MS",
    "MN_DELIVERY_RETRY_ATTEMPTS",
    "MN_DELIVERY_RETRY_INTERVAL_MS"
  ]
  @runtime_app_keys [
    :job_call_timeout_ms,
    :delivery_retry_attempts,
    :delivery_retry_interval_ms
  ]

  defmodule SlowJob do
    use GenServer

    def child_spec(job_id) do
      %{
        id: {__MODULE__, job_id},
        start: {__MODULE__, :start_link, [job_id]},
        restart: :temporary
      }
    end

    def start_link(job_id), do: GenServer.start_link(__MODULE__, job_id)

    @impl true
    def init(job_id) do
      {:ok, _pid} = Horde.Registry.register(MirrorNeuron.DistributedRegistry, {:job, job_id}, %{})
      {:ok, %{job_id: job_id}}
    end

    @impl true
    def handle_call(:pause, _from, state) do
      Process.sleep(1_000)
      {:reply, {:ok, "paused"}, state}
    end
  end

  setup do
    old_env = Map.new(@runtime_envs, &{&1, System.get_env(&1)})
    old_app = Map.new(@runtime_app_keys, &{&1, Application.get_env(:mirror_neuron, &1)})

    Enum.each(@runtime_envs, &System.delete_env/1)
    Enum.each(@runtime_app_keys, &Application.delete_env(:mirror_neuron, &1))

    on_exit(fn ->
      Enum.each(old_env, fn {key, value} -> restore_system_env(key, value) end)
      Enum.each(old_app, fn {key, value} -> restore_app_env(key, value) end)
    end)

    :ok
  end

  test "runtime control and delivery timing defaults are conservative" do
    assert Runtime.job_call_timeout_ms() == 15_000
    assert Runtime.delivery_retry_attempts() == 50
    assert Runtime.delivery_retry_interval_ms() == 50
  end

  test "runtime control and delivery timing honor env overrides with app fallback" do
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "2500")
    System.put_env("MN_DELIVERY_RETRY_ATTEMPTS", "3")
    System.put_env("MN_DELIVERY_RETRY_INTERVAL_MS", "0")

    assert Runtime.job_call_timeout_ms() == 2_500
    assert Runtime.delivery_retry_attempts() == 3
    assert Runtime.delivery_retry_interval_ms() == 0

    Application.put_env(:mirror_neuron, :job_call_timeout_ms, 4_000)
    Application.put_env(:mirror_neuron, :delivery_retry_attempts, 7)
    Application.put_env(:mirror_neuron, :delivery_retry_interval_ms, 25)
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "0")
    System.put_env("MN_DELIVERY_RETRY_ATTEMPTS", "-1")
    System.put_env("MN_DELIVERY_RETRY_INTERVAL_MS", "invalid")

    assert Runtime.job_call_timeout_ms() == 4_000
    assert Runtime.delivery_retry_attempts() == 7
    assert Runtime.delivery_retry_interval_ms() == 25
  end

  test "missing runtime job returns a structured not-running error" do
    job_id = unique_id("missing-job")

    assert {:error, {:job_not_running, ^job_id}} = Runtime.pause_job(job_id)
    assert Runtime.error_message({:job_not_running, job_id}) =~ "not running"
  end

  test "job control call timeout stays local to the caller" do
    System.put_env("MN_JOB_CALL_TIMEOUT_MS", "10")
    job_id = unique_id("slow-job")
    pid = start_supervised!({SlowJob, job_id})

    capture_log(fn ->
      assert {:error, {:job_call_timeout, ^job_id, 10}} = Runtime.pause_job(job_id)
    end)

    Process.exit(pid, :kill)
  end

  test "delivery retry exhaustion returns structured diagnostics and does not block indefinitely" do
    job_id = unique_id("delivery-job")
    agent_id = "missing-agent"

    capture_log(fn ->
      assert {:error, {:agent_not_running, details}} =
               Runtime.deliver(job_id, agent_id, %{"payload" => "hello"},
                 delivery_retry_attempts: 0,
                 delivery_retry_interval_ms: 0
               )

      assert details["job_id"] == job_id
      assert details["agent_id"] == agent_id
      assert details["retry_attempts"] == 0
      assert details["lookup_attempts"] == 1
    end)
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
