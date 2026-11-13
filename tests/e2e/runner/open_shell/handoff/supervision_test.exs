defmodule MirrorNeuron.OpenShellArtifactHandoffTest.SupervisionTest do
  use MirrorNeuron.OpenShellHandoffCase, async: false

  alias MirrorNeuron.Runner.OpenShell

  test "remote preparation streams before completion and outlives both runner deadlines", ctx do
    worker = Path.join(ctx.root, "worker.py")
    original = File.read!(worker)

    File.write!(
      worker,
      ~S"""
      import json, time
      preparation = {"attempt_id":"attempt", "preparation_id":"cold-model", "kind":"model", "timeout_ms":5000}
      print('__MN_EVENT__'+json.dumps({"type":"runtime_preparation_started", "payload":preparation}), flush=True)
      time.sleep(1.2)
      print('__MN_EVENT__'+json.dumps({"type":"runtime_preparation_finished", "payload":preparation}), flush=True)
      """ <> original
    )

    config =
      ctx.config
      |> Map.put("timeout_seconds", 0.5)
      |> update_in(
        ["environment"],
        &Map.merge(&1, %{
          "MN_WORKFLOW_ATTEMPT_ID" => "attempt",
          "MN_WORKFLOW_STEP_ID" => "generate"
        })
      )

    parent = self()

    opts =
      Keyword.put(ctx.opts, :event_callback, fn type, _ ->
        send(parent, {:live_event, to_string(type)})
      end)

    task = Task.async(fn -> OpenShell.run(%{}, config, opts) end)
    assert_receive {:live_event, "runtime_preparation_started"}, 5_000
    assert Task.yield(task, 0) == nil
    assert {:ok, result} = Task.await(task, 10_000)
    assert result["phase"] == "committed"
    assert File.read!(Path.join(ctx.root, "calls")) == "1"
  end
end
