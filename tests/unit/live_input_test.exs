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
