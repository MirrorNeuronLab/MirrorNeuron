defmodule MirrorNeuron.Runner.OpenShell.CommandTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.OpenShell.Command

  test "environment names containing shell syntax are rejected before command execution" do
    for key <- ["BAD;echo injected", "$(echo injected)", "A=B", "1NAME", "A\nB"] do
      config = %{"command" => ["true"], "environment" => %{key => "value"}}

      assert {:error, reason} =
               Command.build_command(config, "/sandbox/job", job_id: "job", agent_id: "worker")

      assert reason =~ "environment variable name"
    end
  end

  test "ordinary environment names and quoted values remain valid" do
    config = %{"command" => ["true"], "environment" => %{"_NAME_1" => "one'two"}}

    assert {:ok, ["bash", "-lc", wrapper]} =
             Command.build_command(config, "/sandbox/job", job_id: "job", agent_id: "worker")

    assert wrapper =~ "export _NAME_1='one'\"'\"'two'"
  end
end
