defmodule MirrorNeuron.Runtime.DeploymentController.ReadinessTest do
  use MirrorNeuron.RedisStoreCase, async: false
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.DeploymentController.Health

  setup do
    suspend_process(MirrorNeuron.Runtime.LocalRecovery)
    suspend_process(MirrorNeuron.Cluster.Leader)
    :ok
  end

  test "a job that remains pending past the healthy deadline fails deployment readiness" do
    id = persist_job("pending")
    assert {:error, reason} = Health.wait_for_started_job(id, %{"healthy_deadline_ms" => 1_000})
    assert reason =~ "did not become ready"
    assert {:ok, %{"status" => "pending"}} = RedisStore.fetch_job(id)
  end

  test "failed and cancelled jobs retain the cause when readiness is rejected" do
    for status <- ["failed", "cancelled"] do
      id = persist_job(status)
      assert {:error, reason} = Health.wait_for_started_job(id, %{})
      assert reason =~ status
      assert reason =~ "start failure"
    end
  end

  test "running and completed jobs satisfy readiness without changing their state" do
    for status <- ["running", "completed"] do
      id = persist_job(status)
      assert {:ok, %{"status" => ^status}} = Health.wait_for_started_job(id, %{})
    end
  end

  test "missing deployment jobs return the persistence error" do
    assert {:error, _} = Health.wait_for_started_job("missing-job", %{})
  end

  defp persist_job(status) do
    id = "readiness-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             RedisStore.persist_job(id, %{
               "job_id" => id,
               "status" => status,
               "result" => %{"error" => "start failure"}
             })

    id
  end
end
