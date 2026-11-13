defmodule MirrorNeuron.Persistence.RedisStore.LeasesTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore

  test "pending finalization cannot overwrite a newer execution epoch" do
    job_id = "finalization-fence-#{System.unique_integer([:positive])}"
    pending = %{"job_id" => job_id, "status" => "running", "attempt" => 1, "lease_epoch" => 3}

    assert {:error, :interrupted} =
             MirrorNeuron.Runtime.Finalization.commit(
               job_id,
               pending,
               Map.put(pending, "status", "completed"),
               %{type: :job_completed},
               finish: fn _, _, _ -> {:error, :interrupted} end
             )

    assert {:ok, intent} = RedisStore.fetch_job(job_id)
    assert {:ok, _} = RedisStore.persist_job(job_id, Map.put(pending, "lease_epoch", 4))

    assert {:error, {:stale_lease_epoch, 3, 4}} =
             MirrorNeuron.Runtime.Finalization.recover(intent)

    assert {:ok, []} = RedisStore.read_events(job_id)
    RedisStore.delete_job(job_id)
  end

  test "fenced leases reject stale job and agent writes" do
    job_id = "fenced-job-#{System.unique_integer([:positive])}"
    lease_name = "job:#{job_id}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "node-a", 5_000)
    assert lease["epoch"] >= 1

    assert {:error, {:locked, locked}} =
             RedisStore.acquire_fenced_lease(lease_name, "node-b", 5_000)

    assert locked["owner_id"] == "node-a"
    assert locked["epoch"] == lease["epoch"]

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => lease["epoch"]
             })

    assert {:error, {:stale_lease_epoch, stale_epoch, existing_epoch}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "lease_epoch" => lease["epoch"] - 1
             })

    assert stale_epoch == lease["epoch"] - 1
    assert existing_epoch == lease["epoch"]

    assert {:error, {:stale_lease_epoch, stale_agent_epoch, existing_agent_epoch}} =
             RedisStore.persist_agent(job_id, "agent-a", %{
               "agent_id" => "agent-a",
               "status" => "running",
               "metadata" => %{"lease_epoch" => lease["epoch"] - 1}
             })

    assert stale_agent_epoch == lease["epoch"] - 1
    assert existing_agent_epoch == lease["epoch"]

    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-a", lease["epoch"])
    assert {:ok, next_lease} = RedisStore.acquire_fenced_lease(lease_name, "node-b", 5_000)
    assert next_lease["epoch"] > lease["epoch"]
    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-b", next_lease["epoch"])
  end

  test "fenced lease renewal and release enforce ownership" do
    lease_name = "lease-test-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "node-a", 1_000)
    assert :ok = RedisStore.renew_fenced_lease(lease_name, "node-a", lease["epoch"], 1_000)

    assert {:error, :not_owner} =
             RedisStore.renew_fenced_lease(lease_name, "node-b", lease["epoch"], 1_000)

    assert {:error, :not_owner} =
             RedisStore.release_fenced_lease(lease_name, "node-b", lease["epoch"])

    assert :ok = RedisStore.release_fenced_lease(lease_name, "node-a", lease["epoch"])
  end

  test "job deletion reclaims fenced lease epochs", %{namespace: namespace} do
    job_id = "lease-cleanup-job-#{System.unique_integer([:positive])}"
    lease_name = "job:#{job_id}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "runtime", 1_000)
    assert :ok = RedisStore.release_fenced_lease(lease_name, "runtime", lease["epoch"])

    assert {:ok, [_epoch_key]} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "job:#{job_id}*"])
             ])

    assert :ok = RedisStore.delete_job(job_id)

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "job:#{job_id}*"])
             ])
  end

  test "ephemeral fenced lease release removes its epoch", %{namespace: namespace} do
    lease_name = "ephemeral-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = RedisStore.acquire_fenced_lease(lease_name, "dispatcher", 1_000)

    assert :ok =
             RedisStore.release_ephemeral_fenced_lease(
               lease_name,
               "dispatcher",
               lease["epoch"]
             )

    assert {:ok, []} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "KEYS",
               redis_key(namespace, ["lease", "#{lease_name}*"])
             ])
  end

  test "durable write acknowledgement reports timeout when not enough replicas are available" do
    required_replicas = 99
    Application.put_env(:mirror_neuron, :redis_wait_replicas, required_replicas)
    Application.put_env(:mirror_neuron, :redis_wait_timeout_ms, 1)
    job_id = "wait-timeout-#{System.unique_integer([:positive])}"

    assert {:error, {:redis_replication_wait_timeout, acknowledgements, ^required_replicas}} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running"
             })

    assert is_integer(acknowledgements)
    assert acknowledgements < required_replicas
  end
end
