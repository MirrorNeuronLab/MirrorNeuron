defmodule MirrorNeuron.OpenShellArtifactHandoffTest.FailuresTest do
  use MirrorNeuron.OpenShellHandoffCase, async: false

  alias MirrorNeuron.Runner.OpenShell

  test "conflicting modes fail before execution", ctx do
    assert {:error, _} =
             OpenShell.run(%{}, Map.put(ctx.config, "sync_shared_storage", true), ctx.opts)

    assert {:error, _} =
             OpenShell.run(
               %{},
               put_in(ctx.config, ["artifact_handoff", "export_outputs"], "true"),
               ctx.opts
             )

    refute File.exists?(Path.join(ctx.root, "calls"))

    refute File.exists?(Path.join(ctx.root, "calls"))
  end

  test "selected stock block and auxiliary workers require handoff before staging", ctx do
    for handler <- ["block_worker", "block_auxiliary"] do
      config =
        ctx.config
        |> Map.delete("artifact_handoff")
        |> put_in(["environment", "MN_WORKFLOW_STEP_HANDLER"], "mn_sdk.integrations." <> handler)

      assert {:error, _} = OpenShell.run(%{}, config, ctx.opts)
    end

    refute File.exists?(Path.join(ctx.root, "calls"))
  end

  test "worker failure remains visible when output transfer also fails", ctx do
    File.mkdir_p!(Path.join(ctx.root, "sandboxes"))
    File.touch!(Path.join(ctx.root, "sandboxes/fail-transfer"))
    assert {:error, error} = OpenShell.run(%{"fail" => true}, ctx.config, ctx.opts)
    assert error["execution"]["exit_code"] == 7
    assert error["transfer_error"]
    File.rm!(Path.join(ctx.root, "sandboxes/fail-transfer"))
    assert {:error, result} = OpenShell.run(%{"fail" => true}, ctx.config, ctx.opts)
    assert result["phase"] == "execution_failed"
    assert result["artifact_receipt"]
    assert File.read!(Path.join(ctx.root, "calls")) == "1"
  end

  test "cleanup warning does not invalidate committed success", ctx do
    File.mkdir_p!(Path.join(ctx.root, "sandboxes"))
    File.touch!(Path.join(ctx.root, "sandboxes/fail-cleanup"))
    assert {:ok, result} = OpenShell.run(%{}, ctx.config, ctx.opts)
    assert result["cleanup_warning"]
  end

  test "ambiguous dispatch is blocked and never automatically executed", ctx do
    File.mkdir_p!(Path.join(ctx.root, "sandboxes"))
    File.touch!(Path.join(ctx.root, "sandboxes/fail-exec"))
    assert {:error, first} = OpenShell.run(%{}, ctx.config, ctx.opts)
    assert first["phase"] == "unknown_blocked"
    File.rm!(Path.join(ctx.root, "sandboxes/fail-exec"))
    assert {:error, again} = OpenShell.run(%{}, ctx.config, ctx.opts)
    assert again["phase"] == "unknown_blocked"
    refute File.exists?(Path.join(ctx.root, "calls"))
  end
end
