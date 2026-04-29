defmodule MirrorNeuron.CLI.DependencyCheckTest do
  use ExUnit.Case, async: true

  @tag :skip
  test "legacy Elixir CLI dependency checks are disabled because the active CLI lives in mn-cli" do
    assert true
  end
end
