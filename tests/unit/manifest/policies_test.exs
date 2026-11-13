defmodule MirrorNeuron.ManifestTest.PoliciesTest do
  use MirrorNeuron.ManifestCase, async: true

  alias MirrorNeuron.Manifest

  test "accepts service declarations and required service checks" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "services",
      "entrypoints" => ["worker"],
      "required_services" => [
        %{
          "name" => "ollama",
          "origin" => "external",
          "checks" => [
            %{
              "name" => "health",
              "type" => "http",
              "url" => "${config.llm.api_base}/api/tags",
              "timeout_ms" => 1000
            }
          ]
        }
      ],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root",
          "services" => [%{"name" => "agent-api", "port" => 8080}],
          "requires_services" => [%{"name" => "ollama"}]
        }
      ],
      "edges" => []
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert [%{"name" => "ollama"}] = normalized.required_services
    assert [%{"name" => "agent-api", "port" => 8080}] = hd(normalized.nodes).services

    serialized = Manifest.to_map(normalized)

    refute Map.has_key?(serialized, "nodes")
    refute Map.has_key?(serialized, "edges")

    assert get_in(serialized, [
             "flow",
             "nodes",
             Access.at(0),
             "requires_services",
             Access.at(0),
             "name"
           ]) == "ollama"
  end

  test "rejects malformed service declarations" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bad-services",
      "entrypoints" => ["worker"],
      "required_services" => [
        %{"name" => "bad service", "checks" => [%{"type" => "smtp"}]}
      ],
      "nodes" => [%{"node_id" => "worker", "agent_type" => "executor", "role" => "root"}],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "required_services.0.name"))
    assert Enum.any?(errors, &String.contains?(&1, "checks.0.type"))
  end

  test "accepts auto recovery mode for adaptive runtime reliability" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "auto-recovery-mode",
      "entrypoints" => ["router"],
      "nodes" => [%{"node_id" => "router", "agent_type" => "router", "role" => "root"}],
      "edges" => [],
      "policies" => %{"recovery_mode" => "auto"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.policies["recovery_mode"] == "auto"
  end

  test "rejects invalid lifecycle policies" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bad-policy",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root",
          "policies" => %{"reschedule" => %{"unlimited" => "yes"}}
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => -1,
          "mode" => "always",
          "delay_function" => "random"
        }
      }
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "policies.restart.attempts"))
    assert Enum.any?(errors, &String.contains?(&1, "policies.restart.mode"))
    assert Enum.any?(errors, &String.contains?(&1, "policies.restart.delay_function"))
    assert Enum.any?(errors, &String.contains?(&1, "nodes.worker.policies.reschedule.unlimited"))
  end

  test "accepts event-driven DAG triggers and validates DAG trigger rules" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "event-driven-dag",
      "entrypoints" => ["sensor"],
      "triggers" => [
        %{
          "name" => "dataset-uploaded",
          "enabled" => true,
          "event_type" => "file_uploaded",
          "filters" => %{"path" => %{"prefix" => "/datasets/"}}
        }
      ],
      "flow" => %{
        "steps" => [
          %{"id" => "sensor", "run" => "sensor"},
          %{
            "id" => "publish",
            "run" => "publish",
            "trigger_rule" => %{"rule" => "quorum_success", "quorum" => 1}
          }
        ],
        "graph" => %{
          "edges" => [%{"id" => "sensor-publish", "from" => "sensor", "to" => "publish"}]
        }
      },
      "nodes" => [
        %{"node_id" => "sensor", "agent_type" => "sensor", "role" => "root"},
        %{"node_id" => "publish", "agent_type" => "executor"}
      ],
      "edges" => [
        %{"from_node" => "sensor", "to_node" => "publish", "message_type" => "file_ready"}
      ],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, normalized} = Manifest.load(flow_manifest(manifest))
    assert normalized.triggers |> hd() |> Map.fetch!("event_type") == "file_uploaded"

    assert {:error, errors} =
             Manifest.load(
               put_in(
                 flow_manifest(manifest),
                 ["flow", "steps", Access.at(1), "trigger_rule", "quorum"],
                 2
               )
             )

    assert Enum.any?(errors, &String.contains?(&1, "quorum 2 exceeds"))
  end
end
