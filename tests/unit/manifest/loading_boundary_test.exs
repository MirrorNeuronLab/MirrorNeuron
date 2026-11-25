defmodule MirrorNeuron.Manifest.LoadingBoundaryTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Manifest

  test "rejects JSON values that are not manifest objects" do
    for input <- ["null", "[]", "42", "true", ~s("a string")] do
      assert {:error, ["manifest must be an object"]} = Manifest.load(input)
    end
  end

  test "rejects malformed topology containers before normalization" do
    for {path, value} <- [
          {["flow"], []},
          {["flow", "nodes"], %{}},
          {["flow", "nodes"], [nil]},
          {["flow", "edges"], [42]},
          {["flow", "steps"], [false]},
          {["flow", "graph"], "bad"}
        ] do
      assert {:error, errors} = Manifest.load(put_in(base(), path, value))
      assert Enum.any?(errors, &String.contains?(&1, Enum.join(path, ".")))
    end
  end

  test "rejects compound node and workflow identifiers without raising" do
    for {path, value} <- [
          {["flow", "nodes", Access.at(0), "node_id"], %{}},
          {["flow", "steps"], [%{"id" => %{}, "run" => "worker"}]},
          {["flow", "graph"], %{"edges" => [%{"from" => %{}, "to" => "worker"}]}}
        ] do
      assert {:error, errors} = Manifest.load(put_in(base(), path, value))
      assert errors != []
    end
  end

  test "validates disconnected workflow components and preserves edge diagnostics" do
    steps = for id <- ~w(a b c d), do: %{"id" => id, "run" => "worker"}
    edges = [%{"from" => "a", "to" => "b"}, %{"from" => "c", "to" => "d"}]

    input =
      base() |> put_in(["flow", "steps"], steps) |> put_in(["flow", "graph"], %{"edges" => edges})

    assert {:ok, manifest} = Manifest.load(input)
    malformed = put_in(manifest.flow["graph"]["edges"], [42])
    assert {:error, ["workflow edge must be an object"]} = Manifest.validate(malformed)

    for {edge, reason} <- [
          {%{"from" => "d", "to" => "c"}, "workflow graph must be acyclic"},
          {%{"from" => "c", "to" => "c"}, "workflow edge cannot point from c to itself"},
          {%{"from" => "c", "to" => "unknown"},
           "workflow edge references missing to step unknown"}
        ] do
      assert {:error, [^reason]} =
               Manifest.load(put_in(input, ["flow", "graph", "edges"], edges ++ [edge]))
    end
  end

  test "rejects malformed scheduling policy values" do
    for policies <- [
          %{"scheduler" => []},
          %{"job_type" => %{}},
          %{"scheduler_strategy" => %{}},
          %{"scheduler" => %{"strategy" => []}}
        ] do
      assert {:error, errors} = Manifest.load(Map.put(base(), "policies", policies))
      assert errors != []
    end
  end

  test "valid definitions round trip through JSON without losing extensions" do
    input = Map.put(base(), "custom", %{"enabled" => false, "tags" => ["one"]})
    assert {:ok, first} = Manifest.load(input)
    assert {:ok, second} = first |> Manifest.to_map() |> Jason.encode!() |> Manifest.load()
    assert Manifest.to_map(first) == Manifest.to_map(second)
  end

  defp base do
    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "validation-boundary",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [%{"node_id" => "worker", "agent_type" => "executor"}],
        "edges" => []
      }
    }
  end
end
