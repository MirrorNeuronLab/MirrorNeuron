defmodule MirrorNeuron.ManifestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.ManifestCase
    end
  end

  def bounded_response_agent do
    %{
      "kind" => "bounded_mcp",
      "service" => %{
        "name" => "robot-mcp",
        "path" => "/mcp",
        "required_tags" => ["mcp", "robot"]
      },
      "tools" => %{
        "user" => %{
          "get_robot_status" => %{
            "effect" => "read",
            "arguments" => %{}
          },
          "navigate_to_zone" => %{
            "effect" => "dispatch",
            "arguments" => %{
              "zone" => %{"type" => "string", "enum" => ~w(zone_a zone_b zone_c)}
            }
          }
        },
        "internal" => %{
          "get_navigation_operation" => %{
            "arguments" => %{"operation_id" => %{"type" => "string"}}
          }
        }
      },
      "operations" => %{
        "navigate_to_zone" => %{
          "id_field" => "operation_id",
          "poll_tool" => "get_navigation_operation",
          "poll_argument" => "operation_id",
          "poll_interval_ms" => 1_000,
          "timeout_seconds" => 180
        }
      },
      "memory" => %{
        "enabled" => true,
        "mode" => "explicit",
        "path" => "knowledge/learned",
        "types" => ~w(destination_alias control_constraint capability_note),
        "max_active_records" => 500
      }
    }
  end

  def flow_manifest(manifest) do
    {nodes, manifest} = Map.pop(manifest, "nodes")
    {edges, manifest} = Map.pop(manifest, "edges")

    if is_list(nodes) or is_list(edges) do
      flow = Map.get(manifest, "flow", %{}) || %{}

      flow =
        flow
        |> maybe_put_topology("nodes", nodes)
        |> maybe_put_topology("edges", edges)

      manifest
      |> Map.put("flow", flow)
      |> Map.put_new("apiVersion", "mn.workflow/v1")
      |> Map.put_new("kind", "Workflow")
    else
      manifest
      |> Map.put_new("apiVersion", "mn.workflow/v1")
      |> Map.put_new("kind", "Workflow")
    end
  end

  def maybe_put_topology(flow, _key, nil), do: flow
  def maybe_put_topology(flow, key, value), do: Map.put(flow, key, value)
end
