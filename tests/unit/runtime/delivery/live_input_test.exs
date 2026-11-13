defmodule MirrorNeuron.Runtime.LiveInputTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.LiveInput

  @declaration %{
    "entrypoint" => "ingress",
    "message_type" => "cctv_operator_steer",
    "schema" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "instruction" => %{"type" => "string", "maxLength" => 500},
        "analyze_now" => %{"type" => "boolean", "default" => true},
        "clear" => %{"type" => "boolean", "default" => false}
      }
    }
  }

  test "resolves only a manifest-declared entrypoint and message route" do
    run = run_with_declaration(@declaration)

    assert {:ok, @declaration} = LiveInput.resolve_contract(run, "steer_monitoring")

    assert {:error, {:invalid_live_input, _reason}} =
             LiveInput.resolve_contract(run, "other")

    invalid =
      put_in(
        run,
        ["manifest", "contract", "live_inputs", "steer_monitoring", "entrypoint"],
        "worker"
      )

    assert {:error, {:invalid_live_input, _reason}} =
             LiveInput.resolve_contract(invalid, "steer_monitoring")
  end

  test "validates live input schema, applies defaults, and rejects routing fields" do
    schema = @declaration["schema"]

    assert {:ok,
            %{
              "instruction" => "Watch the loading dock",
              "analyze_now" => true,
              "clear" => false
            }} =
             LiveInput.validate_payload(
               %{"instruction" => "Watch the loading dock"},
               schema
             )

    assert {:error, {:invalid_live_input, reason}} =
             LiveInput.validate_payload(
               %{"instruction" => "Watch", "agent_id" => "detector"},
               schema
             )

    assert reason =~ "unknown fields"
  end

  test "enforces field types and string limits" do
    schema = @declaration["schema"]

    assert {:error, {:invalid_live_input, reason}} =
             LiveInput.validate_payload(%{"analyze_now" => "yes"}, schema)

    assert reason =~ "boolean"

    assert {:error, {:invalid_live_input, reason}} =
             LiveInput.validate_payload(%{"instruction" => String.duplicate("x", 501)}, schema)

    assert reason =~ "too long"
  end

  test "declared controls ignore busy downstream models but retain entrypoint admission" do
    contract = run_with_declaration(@declaration)["manifest"]["contract"]

    command = %{
      "class" => "command",
      "type" => "cctv_operator_steer",
      "headers" => %{"mn.live_input_id" => "steer_monitoring"},
      "payload" => %{"instruction" => "Watch helmet use"}
    }

    assert LiveInput.pressure_targets(contract, "ingress", command, ["gpu", "rag"]) == ["ingress"]

    for invalid <- [
          put_in(command, ["class"], "event"),
          put_in(command, ["type"], "other"),
          put_in(command, ["headers", "mn.live_input_id"], "unknown"),
          put_in(command, ["payload", "analyze_now"], "invalid")
        ] do
      assert LiveInput.pressure_targets(contract, "ingress", invalid, ["gpu", "rag"]) ==
               ["ingress", "gpu", "rag"]
    end

    assert LiveInput.pressure_targets(contract, "other", command, ["gpu"]) == ["other", "gpu"]

    for body <- ["ordinary input", [1, 2], nil, 42] do
      assert LiveInput.pressure_targets(contract, "ingress", body, ["gpu"]) == ["ingress", "gpu"]
    end
  end

  defp run_with_declaration(declaration) do
    %{
      "status" => "running",
      "manifest" => %{
        "entrypoints" => ["ingress"],
        "contract" => %{"live_inputs" => %{"steer_monitoring" => declaration}},
        "edges" => [
          %{
            "from_node" => "ingress",
            "to_node" => "adaptive_frame_sampler",
            "message_type" => "cctv_operator_steer"
          }
        ]
      }
    }
  end
end
