defmodule MirrorNeuron.Runner.ResultTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.Result

  setup do
    old_secret = System.get_env("MN_RUNNER_RESULT_SECRET")
    old_max_artifact_bytes = System.get_env("MN_MAX_ARTIFACT_BYTES")

    on_exit(fn ->
      restore_env("MN_RUNNER_RESULT_SECRET", old_secret)
      restore_env("MN_MAX_ARTIFACT_BYTES", old_max_artifact_bytes)
    end)
  end

  test "sanitize redacts sensitive environment values from string fields" do
    System.put_env("MN_RUNNER_RESULT_SECRET", "super-secret-value")
    System.put_env("MN_MAX_ARTIFACT_BYTES", "1000")

    result = Result.sanitize(%{"logs" => "token=super-secret-value", "status" => 0})

    assert result["logs"] == "token=[REDACTED]"
    assert result["status"] == 0
  end

  test "sanitize truncates oversized string fields" do
    System.put_env("MN_MAX_ARTIFACT_BYTES", "5")

    result = Result.sanitize(%{"artifact" => "abcdef"})

    assert result["artifact"] == "abcde\n[truncated by MN_MAX_ARTIFACT_BYTES]"
  end

  test "sanitize leaves non-map results unchanged" do
    assert Result.sanitize(:ok) == :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
