defmodule MirrorNeuron.Runner.OpenShell.OutputTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.OpenShell.Output

  test "cleanup failure preserves a successful worker result with a warning" do
    output = frame(0) <> "\ncleanup unavailable"
    assert {:ok, result} = Output.extract_result(output, "sandbox", "/workspace", 4)
    assert result["exit_code"] == 0
    assert result["openshell_exit_code"] == 4
    assert result["warning"] =~ "cleanup"
    assert result["cleanup_logs"] =~ "cleanup unavailable"
  end

  test "worker failure remains authoritative when transport cleanup also fails" do
    assert {:ok, result} = Output.extract_result(frame(7), "sandbox", "/workspace", 4)
    assert result["exit_code"] == 7
    refute Map.has_key?(result, "warning")
  end

  test "output without a structured result retains the transport error code" do
    assert {:ok, result} = Output.extract_result("connection failed", "sandbox", "/workspace", 1)
    assert result["exit_code"] == 1
    assert result["logs"] == "connection failed"
  end

  defp frame(code) do
    "__MN_RESULT_START__\n" <>
      Jason.encode!(%{"exit_code" => code, "stdout" => "output", "stderr" => ""}) <>
      "\n__MN_RESULT_END__"
  end
end
