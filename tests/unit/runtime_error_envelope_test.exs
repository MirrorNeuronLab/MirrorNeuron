defmodule MirrorNeuron.Runtime.ErrorEnvelopeTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runtime.ErrorEnvelope

  test "command diagnostics preserve the exception tail, exit code and attempt without duplicate raw output" do
    logs =
      "Traceback (most recent call last):\n" <>
        String.duplicate("frame\n", 900) <>
        "FileNotFoundError: source manifest is unavailable\n"

    error =
      ErrorEnvelope.normalize(%{
        "exit_code" => 1,
        "logs" => logs,
        "stdout" => logs,
        "raw_output" => logs,
        "attempts" => 2,
        "runner" => "host_local"
      })

    assert error["code"] == "runtime.command.failed"

    assert error["desc"] ==
             "Command exited with code 1: FileNotFoundError: source manifest is unavailable"

    assert error["details"]["exit_code"] == 1
    assert error["details"]["attempts"] == 2
    assert error["details"]["logs"] =~ "[earlier output omitted]"

    assert String.ends_with?(
             error["details"]["logs"],
             "FileNotFoundError: source manifest is unavailable\n"
           )

    refute Map.has_key?(error["details"], "raw_output")
    refute Map.has_key?(error["details"], "stdout")
    assert byte_size(Jason.encode!(error)) < 16_384
    assert ErrorEnvelope.normalize(error)["details"] == error["details"]
  end

  test "empty diagnostics do not invent a cause" do
    error = ErrorEnvelope.normalize(%{exit_code: 2})
    assert error["desc"] == "Command exited with code 2"
    assert error["details"]["logs"] == ""
  end

  test "diagnostic summaries and tails redact credentials" do
    System.put_env("MN_TEST_FAILURE_TOKEN", "private-runtime-value")
    on_exit(fn -> System.delete_env("MN_TEST_FAILURE_TOKEN") end)

    error =
      ErrorEnvelope.normalize(%{
        "exit_code" => 1,
        "stderr" =>
          "Authorization: Bearer auth-value\napi_key=api-value\nError: private-runtime-value"
      })

    encoded = Jason.encode!(error)
    refute encoded =~ "auth-value"
    refute encoded =~ "api-value"
    refute encoded =~ "private-runtime-value"
    assert encoded =~ "[REDACTED]"
  end
end
