defmodule MirrorNeuron.PathSafetyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.PathSafety

  test "accepts relative file paths inside the current root" do
    assert PathSafety.safe_relative_path?("payload.txt")
    assert PathSafety.safe_relative_path?("payloads/input.json")
    assert PathSafety.safe_relative_path?("payloads\\input.json")
  end

  test "rejects empty absolute and traversal paths" do
    refute PathSafety.safe_relative_path?(nil)
    refute PathSafety.safe_relative_path?("")
    refute PathSafety.safe_relative_path?(".")
    refute PathSafety.safe_relative_path?("/tmp/payload.txt")
    refute PathSafety.safe_relative_path?("../payload.txt")
    refute PathSafety.safe_relative_path?("payloads/../secret.txt")
    refute PathSafety.safe_relative_path?("payloads/./secret.txt")
  end

  test "unsafe predicate mirrors safe predicate" do
    assert PathSafety.unsafe_relative_path?("../secret.txt")
    refute PathSafety.unsafe_relative_path?("payloads/input.json")
  end
end
