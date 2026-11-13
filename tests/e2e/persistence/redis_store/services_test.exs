defmodule MirrorNeuron.Persistence.RedisStore.ServicesTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ServiceRegistry

  test "service registry persists, resolves passing instances, and deregisters by agent" do
    job_id = "service-registry-#{System.unique_integer([:positive])}"

    passing = %{
      "id" => "#{job_id}:worker:ollama",
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab",
      "address" => "127.0.0.1",
      "port" => 11_434,
      "tags" => ["gpu"],
      "status" => "passing"
    }

    critical =
      passing
      |> Map.put("id", "#{job_id}:other:ollama")
      |> Map.put("agent_id", "other")
      |> Map.put("node", "cpu@lab")
      |> Map.put("status", "critical")

    assert {:ok, _} = ServiceRegistry.register(passing)
    assert {:ok, _} = ServiceRegistry.register(critical)

    assert {:ok, [resolved]} = ServiceRegistry.resolve("ollama", tags: ["gpu"])
    assert resolved["id"] == passing["id"]
    assert resolved["status"] == "passing"

    assert {:ok, all} = ServiceRegistry.list(name: "ollama", passing_only: false)
    assert Enum.count(all, &(&1["job_id"] == job_id)) == 2

    assert ServiceRegistry.requirements_satisfied_on_node?(
             [%{"name" => "ollama", "tags" => ["gpu"]}],
             "gpu@lab"
           )

    refute ServiceRegistry.requirements_satisfied_on_node?(
             [%{"name" => "ollama", "tags" => ["gpu"]}],
             "cpu@lab"
           )

    assert :ok = ServiceRegistry.deregister_agent(job_id, "worker")
    assert {:ok, []} = ServiceRegistry.resolve("ollama", tags: ["gpu"])

    assert :ok = ServiceRegistry.deregister_job(job_id)
  end

  test "re-registering a service replaces its ownership indexes", %{namespace: namespace} do
    instance_id = "reindexed-service-#{System.unique_integer([:positive])}"

    original = %{
      "id" => instance_id,
      "name" => "ollama-old",
      "job_id" => "job-old",
      "agent_id" => "agent-old",
      "node" => "node-old@lab"
    }

    replacement = %{
      "id" => instance_id,
      "name" => "ollama-new",
      "job_id" => "job-new",
      "agent_id" => "agent-new",
      "node" => "node-new@lab"
    }

    assert {:ok, _service} = ServiceRegistry.register(original)
    assert {:ok, _service} = ServiceRegistry.register(replacement)

    for {index, old_value, new_value} <- [
          {"name", "ollama-old", "ollama-new"},
          {"job", "job-old", "job-new"},
          {"agent", "agent-old", "agent-new"},
          {"node", "node-old@lab", "node-new@lab"}
        ] do
      assert {:ok, 0} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 redis_key(namespace, ["service", index, old_value]),
                 instance_id
               ])

      assert {:ok, 1} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "SISMEMBER",
                 redis_key(namespace, ["service", index, new_value]),
                 instance_id
               ])
    end

    assert :ok = ServiceRegistry.deregister_job("job-old")
    assert {:ok, %{"job_id" => "job-new"}} = RedisStore.fetch_service_instance(instance_id)
    assert :ok = ServiceRegistry.deregister_job("job-new")
    assert {:error, _reason} = RedisStore.fetch_service_instance(instance_id)
  end

  test "health updates cannot resurrect a deregistered service" do
    job_id = "deregistered-health-service-#{System.unique_integer([:positive])}"
    instance_id = "#{job_id}:worker:agent-api"

    assert {:ok, registered_service} =
             ServiceRegistry.register(%{
               "id" => instance_id,
               "name" => "agent-api",
               "job_id" => job_id,
               "agent_id" => "worker",
               "node" => to_string(Node.self())
             })

    assert :ok = ServiceRegistry.deregister_job(job_id)

    assert {:error, _reason} =
             RedisStore.update_service_instance_if_exists(
               instance_id,
               Map.put(registered_service, "status", "passing")
             )

    assert {:ok, []} = ServiceRegistry.list(job_id: job_id, passing_only: false)
  end

  test "concurrent service registration cannot leave stale ownership", %{namespace: namespace} do
    instance_id = "concurrent-service-#{System.unique_integer([:positive])}"

    services =
      for suffix <- ["a", "b"] do
        %{
          "id" => instance_id,
          "name" => "ollama-#{suffix}",
          "job_id" => "job-#{suffix}",
          "agent_id" => "agent-#{suffix}",
          "node" => "node-#{suffix}@lab"
        }
      end

    for _round <- 1..10 do
      results =
        services
        |> Task.async_stream(&ServiceRegistry.register/1,
          max_concurrency: 2,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, {:ok, _service}}, &1))
      assert {:ok, winner} = RedisStore.fetch_service_instance(instance_id)

      ownership =
        Enum.map(services, fn service ->
          {:ok, membership} =
            Redix.command(MirrorNeuron.Redis.Connection, [
              "SISMEMBER",
              redis_key(namespace, ["service", "job", service["job_id"]]),
              instance_id
            ])

          {service["job_id"], membership}
        end)

      assert Enum.sum(Enum.map(ownership, &elem(&1, 1))) == 1
      assert {winner["job_id"], 1} in ownership
    end

    assert :ok = ServiceRegistry.deregister_service(instance_id)
  end

  test "owner cleanup reclaims corrupt service records and every index", %{namespace: namespace} do
    job_id = "corrupt-service-job-#{System.unique_integer([:positive])}"
    instance_id = "#{job_id}:worker:ollama"

    service = %{
      "id" => instance_id,
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab"
    }

    assert {:ok, _service} = ServiceRegistry.register(service)

    assert {:ok, "OK"} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SET",
               redis_key(namespace, ["service", "instance", instance_id]),
               "not-json"
             ])

    assert :ok = ServiceRegistry.deregister_job(job_id)
    assert_service_instance_reclaimed(namespace, instance_id, service)
  end

  test "retention compacts indexes for missing service records", %{namespace: namespace} do
    job_id = "missing-service-job-#{System.unique_integer([:positive])}"
    instance_id = "#{job_id}:worker:ollama"

    service = %{
      "id" => instance_id,
      "name" => "ollama",
      "job_id" => job_id,
      "agent_id" => "worker",
      "node" => "gpu@lab"
    }

    assert {:ok, _service} = ServiceRegistry.register(service)

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["service", "instance", instance_id])
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_service_instances == [instance_id]
    assert result.stale_service_instance_count == 1
    assert_service_instance_reclaimed(namespace, instance_id, service)
  end
end
