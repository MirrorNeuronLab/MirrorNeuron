defmodule MirrorNeuron.Persistence.RedisStore.DeploymentsTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ServiceRegistry

  test "persists deployments and immutable version records" do
    deployment_id = "dep-test-#{System.unique_integer([:positive])}"
    deployment_key = "agent-api"

    assert {:ok, deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => deployment_key,
               "status" => "successful",
               "current_version" => "1"
             })

    assert deployment["deployment_id"] == deployment_id
    assert {:ok, fetched} = RedisStore.fetch_deployment(deployment_id)
    assert fetched["deployment_key"] == deployment_key
    assert {:ok, fetched_by_key} = RedisStore.fetch_deployment_by_key(deployment_key)
    assert fetched_by_key["deployment_id"] == deployment_id

    assert {:ok, version} =
             RedisStore.persist_job_version(deployment_key, "1", %{
               "job_id" => "job-1",
               "manifest" => %{"graph_id" => "agent-api"},
               "stable" => true
             })

    assert version["version"] == "1"
    assert {:ok, fetched_version} = RedisStore.fetch_job_version(deployment_key, "1")
    assert fetched_version["job_id"] == "job-1"
    assert {:ok, [listed_version]} = RedisStore.list_job_versions(deployment_key)
    assert listed_version["stable"] == true
  end

  test "deployment key reassignment removes the previous ownership indexes", %{
    namespace: namespace
  } do
    deployment_id = "reindexed-deployment-#{System.unique_integer([:positive])}"
    old_key = "deployment-old"
    new_key = "deployment-new"

    assert {:ok, _deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => old_key,
               "status" => "running"
             })

    assert {:ok, _deployment} =
             RedisStore.persist_deployment(deployment_id, %{
               "deployment_key" => new_key,
               "status" => "successful"
             })

    assert {:error, _reason} = RedisStore.fetch_deployment_by_key(old_key)

    assert {:ok, %{"deployment_id" => ^deployment_id}} =
             RedisStore.fetch_deployment_by_key(new_key)

    assert {:ok, nil} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "GET",
               redis_key(namespace, ["deployment", "key", old_key, "current"])
             ])

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", old_key, "deployments"]),
               deployment_id
             ])
  end

  test "concurrent deployment updates leave exactly one current owner", %{namespace: namespace} do
    deployment_id = "concurrent-deployment-#{System.unique_integer([:positive])}"
    deployment_keys = ["concurrent-a", "concurrent-b"]

    for _round <- 1..10 do
      results =
        deployment_keys
        |> Task.async_stream(
          fn deployment_key ->
            RedisStore.persist_deployment(deployment_id, %{
              "deployment_key" => deployment_key,
              "status" => "running"
            })
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, {:ok, _deployment}}, &1))
      assert {:ok, winner} = RedisStore.fetch_deployment(deployment_id)

      ownership =
        Enum.map(deployment_keys, fn deployment_key ->
          {:ok, current} =
            Redix.command(MirrorNeuron.Redis.Connection, [
              "GET",
              redis_key(namespace, ["deployment", "key", deployment_key, "current"])
            ])

          {:ok, membership} =
            Redix.command(MirrorNeuron.Redis.Connection, [
              "SISMEMBER",
              redis_key(namespace, ["deployment", "key", deployment_key, "deployments"]),
              deployment_id
            ])

          {deployment_key, current, membership}
        end)

      assert Enum.count(ownership, fn {_key, current, member} ->
               current == deployment_id and member == 1
             end) == 1

      assert {winner["deployment_key"], deployment_id, 1} in ownership
    end
  end

  test "retention compacts missing deployment metadata and preserves corrupt records", %{
    namespace: namespace
  } do
    suspend_retention()
    missing_id = "missing-deployment-#{System.unique_integer([:positive])}"
    corrupt_id = "corrupt-deployment-#{System.unique_integer([:positive])}"
    missing_key = "missing-deployment-key"
    corrupt_key = "corrupt-deployment-key"

    for {deployment_id, deployment_key} <- [
          {missing_id, missing_key},
          {corrupt_id, corrupt_key}
        ] do
      assert {:ok, _deployment} =
               RedisStore.persist_deployment(deployment_id, %{
                 "deployment_key" => deployment_key,
                 "status" => "successful"
               })

      assert {:ok, _version} =
               RedisStore.persist_job_version(deployment_key, "1", %{"job_id" => "job-1"})
    end

    assert {:ok, 2} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["deployment", missing_id]),
               redis_key(namespace, ["deployment", "key", missing_key, "version", "1"])
             ])

    assert {:ok, ["OK", "OK"]} =
             Redix.pipeline(MirrorNeuron.Redis.Connection, [
               [
                 "SET",
                 redis_key(namespace, ["deployment", corrupt_id]),
                 "not-json"
               ],
               [
                 "SET",
                 redis_key(namespace, ["deployment", "key", corrupt_key, "version", "1"]),
                 "not-json"
               ]
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_deployments == [missing_id]
    assert result.stale_deployment_count == 1
    assert result.stale_deployment_version_count == 1

    assert_deployment_membership(namespace, missing_id, missing_key, 0, nil)
    assert_deployment_membership(namespace, corrupt_id, corrupt_key, 1, corrupt_id)

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", missing_key, "versions"]),
               "1"
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["deployment", "key", corrupt_key, "versions"]),
               "1"
             ])
  end

  test "service discovery hides deployment candidates until promoted" do
    assert {:ok, _registered_service} =
             ServiceRegistry.register(%{
               "id" => "svc-candidate",
               "name" => "agent-api",
               "status" => "passing",
               "deployment_key" => "agent-api",
               "deployment_version" => "2",
               "deployment_role" => "canary"
             })

    assert {:ok, []} = ServiceRegistry.resolve("agent-api")
    assert {:ok, [candidate]} = ServiceRegistry.resolve("agent-api", include_candidates: true)
    assert candidate["deployment_role"] == "canary"

    assert {:ok, [_promoted]} = ServiceRegistry.promote_deployment("agent-api", "2")
    assert {:ok, [primary]} = ServiceRegistry.resolve("agent-api")
    assert primary["deployment_role"] == "primary"
  end
end
