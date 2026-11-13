defmodule MirrorNeuron.ManifestMCPProjectionTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest

  test "accepts and preserves the current SDK-derived response-agent contract" do
    source = manifest()
    assert {:ok, loaded} = Manifest.load(source)
    assert loaded.response_service == source["response_service"]
    assert Manifest.to_map(loaded)["response_service"] == source["response_service"]
  end

  test "legacy declarations still omit manual, activity and fixed polling arguments" do
    source =
      manifest()
      |> update_in(["response_service", "agent"], &Map.drop(&1, ~w(manual_content activity)))
      |> update_in(
        ["response_service", "agent", "operations", "review"],
        &Map.delete(&1, "poll_arguments")
      )

    assert {:ok, _} = Manifest.load(source)
  end

  test "rejects unbounded manuals, unknown fields, and invalid activity bindings" do
    for {field, value} <- [
          {"manual_content", String.duplicate("x", 65_537)},
          {"manual_content", 42},
          {"command", "arbitrary command"},
          {"activity", %{"tool" => "review"}},
          {"activity", %{"tool" => "watch_job_activity", "extra" => true}}
        ] do
      assert {:error, _} =
               Manifest.load(put_in(manifest(), ["response_service", "agent", field], value))
    end

    source =
      update_in(
        manifest(),
        ["response_service", "agent", "tools", "internal"],
        &Map.delete(&1, "watch_job_activity")
      )

    assert {:error, _} = Manifest.load(source)
  end

  test "fixed polling arguments cannot replace the correlation identity or escape the declared schema" do
    for arguments <- [
          %{"operation_id" => "another-operation"},
          %{"undeclared" => "value"},
          %{"kind" => "undeclared-kind"},
          %{"kind" => 1},
          nil
        ] do
      source =
        put_in(
          manifest(),
          ["response_service", "agent", "operations", "review", "poll_arguments"],
          arguments
        )

      assert {:error, _} = Manifest.load(source)
    end
  end

  test "tool arguments remain restricted to typed scalars and matching enumerations" do
    for schema <- [
          %{"type" => "object"},
          %{"type" => "array"},
          %{"type" => "unknown"},
          %{"type" => "boolean", "enum" => ["true"]},
          %{"type" => "string", "enum" => []},
          %{"type" => "integer", "enum" => [1, 1]},
          %{"type" => "number", "extra" => true}
        ] do
      source =
        put_in(
          manifest(),
          ["response_service", "agent", "tools", "user", "review", "arguments", "count"],
          schema
        )

      assert {:error, _} = Manifest.load(source)
    end
  end

  defp manifest do
    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "mcp-projection",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [%{"node_id" => "worker", "agent_type" => "executor"}],
        "edges" => []
      },
      "response_service" => %{
        "enabled" => true,
        "agent" => %{
          "kind" => "bounded_mcp",
          "manual_content" => "# Operator manual",
          "service" => %{"name" => "camera-mcp", "path" => "/mcp", "required_tags" => ["mcp"]},
          "activity" => %{"tool" => "watch_job_activity"},
          "tools" => %{
            "user" => %{
              "review" => %{
                "effect" => "dispatch",
                "arguments" => %{
                  "count" => %{"type" => "integer"},
                  "enabled" => %{"type" => "boolean"},
                  "threshold" => %{"type" => "number"},
                  "request_id" => %{"type" => "string"}
                }
              }
            },
            "internal" => %{
              "get_operation_status" => %{
                "arguments" => %{
                  "operation_id" => %{"type" => "string"},
                  "kind" => %{"type" => "string", "enum" => ["command", "video"]}
                }
              },
              "watch_job_activity" => %{
                "arguments" => %{
                  "after_event_id" => %{"type" => "string"},
                  "wait_seconds" => %{"type" => "number"}
                }
              }
            }
          },
          "operations" => %{
            "review" => %{
              "id_field" => "request_id",
              "poll_tool" => "get_operation_status",
              "poll_argument" => "operation_id",
              "poll_interval_ms" => 500,
              "timeout_seconds" => 90,
              "poll_arguments" => %{"kind" => "command"}
            }
          },
          "memory" => %{
            "enabled" => true,
            "mode" => "explicit",
            "path" => "knowledge/learned",
            "types" => ["review_note"],
            "max_active_records" => 100
          }
        }
      }
    }
  end
end
