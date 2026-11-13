defmodule MirrorNeuron.ManifestTest.CompletionTest do
  use MirrorNeuron.ManifestCase, async: true

  alias MirrorNeuron.Manifest

  test "rejects legacy complete_job config keys" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "legacy-completion-config",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_job" => true}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported complete_job"))
  end

  test "rejects bare complete_on_message without output or terminal sink" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bare-complete-on-message",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_on_message" => true}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "complete_on_message requires"))
  end

  test "rejects bare complete_after without output or terminal sink" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bare-complete-after",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{"complete_after" => 2}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))
    assert Enum.any?(errors, &String.contains?(&1, "complete_after requires"))
  end

  test "rejects workflow step nodes that declare complete_run" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "workflow-step-complete-run",
      "entrypoints" => ["step_a"],
      "flow" => %{
        "steps" => [%{"id" => "step_a", "run" => "step_a"}],
        "graph" => %{"edges" => []}
      },
      "nodes" => [
        %{
          "node_id" => "step_a",
          "agent_type" => "executor",
          "config" => %{"complete_run" => true}
        }
      ],
      "edges" => []
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))

    assert Enum.any?(
             errors,
             &String.contains?(&1, "workflow step node step_a cannot declare complete_run")
           )
  end

  test "rejects terminal sinks with outgoing edges" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "terminal-sink-outgoing-edge",
      "entrypoints" => ["sink"],
      "nodes" => [
        %{
          "node_id" => "sink",
          "agent_type" => "aggregator",
          "config" => %{
            "complete_on_message" => true,
            "terminal_sink" => true,
            "complete_run" => true
          }
        },
        %{"node_id" => "after_sink", "agent_type" => "aggregator"}
      ],
      "edges" => [
        %{"from_node" => "sink", "to_node" => "after_sink", "message_type" => "done"}
      ]
    }

    assert {:error, errors} = Manifest.load(flow_manifest(manifest))

    assert Enum.any?(
             errors,
             &String.contains?(&1, "terminal sink sink must not have outgoing edges")
           )
  end
end
