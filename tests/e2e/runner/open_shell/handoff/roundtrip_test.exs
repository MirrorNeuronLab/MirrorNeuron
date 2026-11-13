defmodule MirrorNeuron.OpenShellArtifactHandoffTest.RoundtripTest do
  use MirrorNeuron.OpenShellHandoffCase, async: false

  alias MirrorNeuron.Runner.OpenShell

  test "actual runner commits before cleanup and hands off across replacement sandbox", ctx do
    assert {:ok, result} = OpenShell.run(%{}, ctx.config, ctx.opts)
    ref = result["structured_result"]["outputs"]["html"]
    File.rm_rf!(Path.join(ctx.root, "sandboxes"))
    verify = Map.put(ctx.config, "sandbox_name", "generation-two")

    assert {:ok, next} =
             OpenShell.run(
               %{"html" => ref},
               verify,
               Keyword.put(ctx.opts, :step_instance, "verify")
             )

    assert next["phase"] == "committed"
    assert File.read!(Path.join(ctx.root, "calls")) == "2"
    # Receipt replay succeeds even with no sandbox bytes remaining.
    File.rm_rf!(Path.join(ctx.root, "sandboxes"))
    assert {:ok, ^result} = OpenShell.run(%{}, ctx.config, ctx.opts)
    assert File.read!(Path.join(ctx.root, "calls")) == "2"
  end

  test "transfer retry does not invoke worker twice", ctx do
    File.mkdir_p!(Path.join(ctx.root, "sandboxes"))
    File.touch!(Path.join(ctx.root, "sandboxes/fail-transfer"))
    assert {:error, _} = OpenShell.run(%{}, ctx.config, ctx.opts)
    File.rm!(Path.join(ctx.root, "sandboxes/fail-transfer"))
    assert {:ok, _} = OpenShell.run(%{}, ctx.config, ctx.opts)
    assert File.read!(Path.join(ctx.root, "calls")) == "1"
  end

  test "stable Job identity reaches the worker while receipts retain physical ownership", ctx do
    worker = Path.join(ctx.root, "worker.py")
    original = File.read!(worker)

    File.write!(
      worker,
      """
      import os
      assert os.environ['MN_JOB_ID'] == 'stable-job'
      assert os.environ['MN_WORKFLOW_RUN_ID'] == 'actual-run'
      assert os.environ['MN_BLUEPRINT_FAKE_LLM'] == '1'
      assert os.environ['MN_BLUEPRINT_FAKE_SKILLS'] == '1'
      """ <> original
    )

    config =
      update_in(
        ctx.config,
        ["environment"],
        &Map.merge(&1, %{
          "MN_JOB_ID" => "stable-job",
          "MN_BLUEPRINT_FAKE_LLM" => "1",
          "MN_BLUEPRINT_FAKE_SKILLS" => "1"
        })
      )

    assert {:ok, result} = OpenShell.run(%{}, config, ctx.opts)
    assert result["artifact_receipt"]["producer"]["job_id"] == "handoff-test"
    assert result["artifact_receipt"]["producer"]["run_id"] == "actual-run"
  end

  test "new delivery and lease replay a verified logical receipt without a second invocation",
       ctx do
    payload = %{"attempt" => 1, "attempt_id" => "old-delivery", "deadline_at" => "old-deadline"}

    message =
      MirrorNeuron.Message.new("handoff-test", "runtime", "generate", "init", payload,
        headers: %{
          "mn.workflow.attempt" => 1,
          "mn.workflow.attempt_id" => "old-delivery",
          "mn.workflow.deadline_at" => "old-deadline"
        }
      )

    assert {:ok, original} =
             OpenShell.run(payload, ctx.config, Keyword.put(ctx.opts, :message, message))

    payload = %{
      payload
      | "attempt" => 2,
        "attempt_id" => "new-delivery",
        "deadline_at" => "new-deadline"
    }

    message =
      MirrorNeuron.Message.new("handoff-test", "runtime", "generate", "init", payload,
        headers: %{
          "mn.workflow.attempt" => 2,
          "mn.workflow.attempt_id" => "new-delivery",
          "mn.workflow.deadline_at" => "new-deadline"
        }
      )

    opts =
      ctx.opts
      |> Keyword.put(:lease_epoch, 2)
      |> Keyword.put(:runtime_attempt, 2)
      |> Keyword.put(:message, message)

    assert {:ok, ^original} = OpenShell.run(payload, ctx.config, opts)
    assert File.read!(Path.join(ctx.root, "calls")) == "1"
    assert {:error, _} = OpenShell.run(Map.put(payload, "changed", true), ctx.config, opts)
  end
end
