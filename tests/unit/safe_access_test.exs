defmodule MirrorNeuron.SafeAccessTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.SafeAccess

  test "map_get reads exact keys before string or existing atom fallbacks" do
    assert SafeAccess.map_get(%{"answer" => 42}, "answer") == 42
    assert SafeAccess.map_get(%{"answer" => 42}, :answer) == 42
    assert SafeAccess.map_get(%{answer: false}, "answer", :default) == false
    assert SafeAccess.map_get(%{}, "missing", :default) == :default

    mixed = %{:answer => :atom_value, "answer" => :string_value}

    assert SafeAccess.map_get(mixed, :answer) == :atom_value
    assert SafeAccess.map_get(mixed, "answer") == :string_value
  end

  test "map_fetch reports missing values without creating atom fallbacks" do
    assert SafeAccess.map_fetch(%{answer: 42}, "answer") == {:ok, 42}
    assert SafeAccess.map_fetch(%{}, "definitely_not_an_existing_atom_key") == :error
    assert SafeAccess.map_fetch(:not_a_map, "answer") == :error
  end

  test "keyword_get supports atom and string keys" do
    assert SafeAccess.keyword_get([answer: 42], "answer") == 42
    assert SafeAccess.keyword_get([{"answer", 42}], :answer) == 42
    assert SafeAccess.keyword_get([], "missing", :default) == :default
  end

  test "node_name_to_atom validates distributed node names before conversion" do
    assert {:ok, :"worker@127.0.0.1"} = SafeAccess.node_name_to_atom(" worker@127.0.0.1 ")
    assert {:error, :empty_node_name} = SafeAccess.node_name_to_atom(" ")
    assert {:error, :invalid_node_name} = SafeAccess.node_name_to_atom("worker")
    assert {:error, :invalid_node_name} = SafeAccess.node_name_to_atom("../worker@host")
  end

  test "nonempty_binary_to_atom rejects blank and unsupported values" do
    assert {:ok, :cookie_value} = SafeAccess.nonempty_binary_to_atom(" cookie_value ")
    assert {:error, :empty_atom} = SafeAccess.nonempty_binary_to_atom(" ")
    assert {:error, :invalid_atom} = SafeAccess.nonempty_binary_to_atom(123)
  end
end
