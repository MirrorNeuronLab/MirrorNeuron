defmodule MirrorNeuron.ManifestTest.ResponseServiceTest do
  use MirrorNeuron.ManifestCase, async: true

  alias MirrorNeuron.Manifest

  test "keeps the singular response service outside runtime topology" do
    base =
      flow_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "response-service-test",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "role" => "root"}
        ],
        "edges" => [],
        "response_service" => %{"enabled" => true}
      })

    assert {:ok, manifest} = Manifest.load(base)
    assert manifest.response_service == %{"enabled" => true}
    assert Manifest.to_map(manifest)["response_service"] == %{"enabled" => true}
    assert Enum.map(manifest.nodes, & &1.node_id) == ["worker"]
    assert manifest.services == []

    for invalid <- [
          false,
          %{"enabled" => false},
          %{"enabled" => true, "command" => "python responder.py"},
          %{"enabled" => true, "port" => 9000}
        ] do
      assert {:error, errors} = Manifest.load(Map.put(base, "response_service", invalid))
      assert Enum.any?(errors, &String.contains?(&1, "response_service"))
    end
  end

  test "validates the bounded Job response-agent allowlist" do
    base =
      flow_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "bounded-response-agent-test",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "role" => "root"}
        ],
        "edges" => [],
        "response_service" => %{"enabled" => true, "agent" => bounded_response_agent()}
      })

    assert {:ok, manifest} = Manifest.load(base)
    assert manifest.response_service["agent"]["kind"] == "bounded_mcp"

    description_path = [
      "response_service",
      "agent",
      "tools",
      "user",
      "navigate_to_zone",
      "description"
    ]

    described = put_in(base, description_path, "Move to the requested zone.")
    assert {:ok, described_manifest} = Manifest.load(described)

    assert get_in(Manifest.to_map(described_manifest), description_path) ==
             "Move to the requested zone."

    for invalid <- [nil, 42, %{}, "", " ", String.duplicate("x", 1201)] do
      assert {:error, errors} = Manifest.load(put_in(base, description_path, invalid))
      assert Enum.any?(errors, &String.contains?(&1, "tool descriptions"))
    end

    with_preflight =
      put_in(
        base,
        ["response_service", "agent", "preflight"],
        %{
          "required_for_effects" => ["dispatch"],
          "tool" => "get_robot_status",
          "arguments" => %{},
          "required_result" => %{"connected" => true}
        }
      )

    assert {:ok, manifest} = Manifest.load(with_preflight)

    assert manifest.response_service["agent"]["preflight"]["required_result"] == %{
             "connected" => true
           }

    invalid =
      put_in(
        base,
        ["response_service", "agent", "operations", "navigate_to_zone", "poll_argument"],
        "undeclared_argument"
      )

    assert {:error, errors} = Manifest.load(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "operations must correlate"))

    for invalid_preflight <- [
          Map.put(with_preflight, "response_service", %{
            "enabled" => true,
            "agent" =>
              put_in(
                bounded_response_agent(),
                ["preflight"],
                %{
                  "required_for_effects" => ["dispatch"],
                  "tool" => "navigate_to_zone",
                  "arguments" => %{"zone" => "zone_a"},
                  "required_result" => %{"connected" => true}
                }
              )
          }),
          put_in(
            with_preflight,
            ["response_service", "agent", "preflight", "required_result"],
            %{"connected" => %{"nested" => true}}
          ),
          put_in(
            with_preflight,
            ["response_service", "agent", "preflight", "arguments"],
            %{"undeclared" => "value"}
          )
        ] do
      assert {:error, errors} = Manifest.load(invalid_preflight)
      assert Enum.any?(errors, &String.contains?(&1, "preflight"))
    end

    arbitrary_contract =
      base
      |> put_in(
        ["response_service", "agent", "tools", "user", "navigate_to_zone", "effect"],
        "notify"
      )
      |> put_in(
        ["response_service", "agent", "memory", "types"],
        ~w(recipient_alias control_constraint)
      )

    assert {:ok, _manifest} = Manifest.load(arbitrary_contract)

    asynchronous_read =
      put_in(
        base,
        ["response_service", "agent", "tools", "user", "navigate_to_zone", "effect"],
        "read"
      )

    assert {:ok, _manifest} = Manifest.load(asynchronous_read)

    for invalid_read <- [
          update_in(asynchronous_read, ["response_service", "agent", "tools", "user"], fn tools ->
            Map.delete(tools, "navigate_to_zone")
          end),
          put_in(
            asynchronous_read,
            ["response_service", "agent", "operations", "navigate_to_zone", "poll_tool"],
            "undeclared_poll"
          ),
          put_in(
            asynchronous_read,
            ["response_service", "agent", "operations", "navigate_to_zone", "poll_argument"],
            "undeclared_argument"
          )
        ] do
      assert {:error, errors} = Manifest.load(invalid_read)
      assert Enum.any?(errors, &String.contains?(&1, "operations"))
    end

    undeclared_preflight_effect =
      put_in(
        with_preflight,
        ["response_service", "agent", "preflight", "required_for_effects"],
        ["notify"]
      )

    assert {:error, errors} = Manifest.load(undeclared_preflight_effect)
    assert Enum.any?(errors, &String.contains?(&1, "preflight"))

    for path <- [
          ["response_service", "agent", "tools", "user", "navigate_to_zone", "effect"],
          ["response_service", "agent", "memory", "types"]
        ] do
      invalid_value = if List.last(path) == "effect", do: "unsafe-effect", else: ["unsafe-type"]
      assert {:error, _errors} = Manifest.load(put_in(base, path, invalid_value))
    end
  end
end
