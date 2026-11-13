defmodule MirrorNeuron.Runtime.DeploymentTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ServiceRegistry

  test "deploys a service, stages a canary update, and promotes it" do
    key = "deploy-runtime-#{System.unique_integer([:positive])}"
    manifest_v1 = deployment_service_manifest(key, "v1")

    assert {:ok, first} = deploy_manifest(manifest_v1, deployment_key: key)
    assert first["status"] == "successful"
    job_id = first["job_id"]

    assert {:ok, deployment} = MirrorNeuron.get_deployment(key)
    assert deployment["stable_version"] == "1"
    assert deployment["stable_job_id"] == job_id

    manifest_v2 =
      deployment_service_manifest(key, "v2")
      |> put_in(["policies", "update"], %{
        "strategy" => "canary",
        "canary" => 1,
        "max_parallel" => 1,
        "min_healthy_ms" => 0,
        "healthy_deadline_ms" => 1_000
      })

    assert {:ok, staged} = update_deployment(key, manifest_v2)
    assert staged["status"] == "awaiting_promotion"
    assert staged["deployment"]["target_version"] == "2"

    assert {:ok, promoted} = MirrorNeuron.promote_deployment(key)
    assert promoted["status"] == "successful"
    assert promoted["deployment"]["stable_version"] == "2"

    assert {:ok, services} = ServiceRegistry.resolve("deploy-runtime-api")
    assert Enum.any?(services, &(&1["deployment_version"] == "2"))

    MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end
end
