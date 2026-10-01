defmodule MirrorNeuron.OpenShellArtifactHandoffTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runner.OpenShell

  setup do
    root = Path.join(System.tmp_dir!(), "handoff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    values =
      for key <- ["MN_SHARED_STORAGE_ROOT", "FAKE_SANDBOX_ROOT", "OPENSHELL_GATEWAY_ENDPOINT"],
          into: %{},
          do: {key, System.get_env(key)}

    System.put_env("MN_SHARED_STORAGE_ROOT", root)
    System.put_env("FAKE_SANDBOX_ROOT", Path.join(root, "sandboxes"))
    System.put_env("OPENSHELL_GATEWAY_ENDPOINT", "http://fake.invalid")

    on_exit(fn ->
      Enum.each(values, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(root)
    end)

    sdk = Path.expand("../mn-python-sdk", File.cwd!())
    worker = Path.join(root, "worker.py")

    File.write!(worker, """
    import json, os, sys
    from pathlib import Path
    sys.path.insert(0, #{Jason.encode!(sdk)})
    from mn_sdk.artifact_handoff import output_directory, register_output, resolve_input
    root=Path(#{Jason.encode!(root)})
    count=root/'calls'
    count.write_text(str(int(count.read_text())+1) if count.exists() else '1')
    payload=json.loads(Path(os.environ['MN_INPUT_FILE']).read_text())
    data=resolve_input(payload['html']).read_text() if 'html' in payload else 'hello'
    (output_directory()/'index.html').write_text(data)
    ref=register_output('index.html',kind='html')
    print(json.dumps({'outputs':{'html':ref},'artifacts':[ref],'metrics':{},'status':'completed'}))
    if payload.get('fail'): sys.exit(7)
    """)

    config = %{
      "sandbox_cli" => Path.expand("tests/handoff/fake_openshell.py"),
      "sandbox_name" => "generation-one",
      "reuse_shared_sandbox" => true,
      "artifact_handoff" => %{"version" => "mn.artifact_handoff/v1"},
      "upload_paths" => [%{"source" => worker, "target" => "worker.py"}],
      "workdir" => "/sandbox/job",
      "command" => [Path.expand("../mn-system-tests/.venv/bin/python"), "worker.py"],
      "environment" => %{"MN_JOB_SHARED_STORAGE_ROOT" => Path.join(root, "submission")}
    }

    opts = [
      job_id: "handoff-test",
      run_id: "actual-run",
      step_instance: "generate",
      attempt: 1,
      lease_epoch: 1,
      lease_validator: fn _, _ -> :ok end,
      agent_id: "generate"
    ]

    {:ok, root: root, config: config, opts: opts}
  end

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

  test "conflicting modes fail before execution", ctx do
    assert {:error, _} =
             OpenShell.run(%{}, Map.put(ctx.config, "sync_shared_storage", true), ctx.opts)

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

  test "code-generation blueprint uses committed references and exports verified HTML", ctx do
    demo = Path.expand("../../mn-blueprints/demo_openshell_code_generation", File.cwd!())
    python = Path.expand("../mn-system-tests/.venv/bin/python")

    script = """
    from pathlib import Path
    from types import SimpleNamespace
    import worker
    def fake(request):
        Path(request.folder, 'index.html').write_text('<!doctype html><html lang="en"><title>pizza</title><style></style><main><input><button>pizza</button></main><script></script>' + ' ' * 1100 + '</html>')
        return SimpleNamespace(as_dict=lambda: {'model':'fake','session_id':'one-call'})
    worker.run_opencode=fake
    worker.main()
    """

    config =
      ctx.config
      |> Map.put("upload_paths", [
        %{"source" => Path.join(demo, "payloads/worker"), "target" => "worker"},
        %{"source" => Path.join(demo, "payloads/skills"), "target" => "skills"}
      ])
      |> Map.put("workdir", "/sandbox/job/worker")
      |> Map.put("command", [python, "-c", script])

    assert {:ok, generated} = OpenShell.run(%{}, config, ctx.opts)
    File.rm_rf!(Path.join(ctx.root, "sandboxes"))

    config =
      config
      |> Map.put("sandbox_name", "replacement")
      |> Map.put("command", [python, "worker.py", "--verify-only"])
      |> put_in(["artifact_handoff", "export_outputs"], true)
      |> put_in(
        ["environment", "MN_JOB_OUTPUT_DIR"],
        Path.join(ctx.root, "submission/outputs/user")
      )

    assert {:ok, verified} =
             OpenShell.run(
               generated["structured_result"]["outputs"],
               config,
               Keyword.put(ctx.opts, :step_instance, "verify")
             )

    assert verified["phase"] == "committed"
    assert File.exists?(Path.join(ctx.root, "submission/outputs/user/index.html"))
    assert File.exists?(Path.join(ctx.root, "submission/outputs/user/verification.json"))
  end

  test "advisor binding runs with immutable admission and no ledger in sandbox", ctx do
    payloads =
      Path.expand(
        "../../otterdesk-blueprints/software_architecture_advisor/payloads",
        File.cwd!()
      )

    python = Path.expand("../mn-system-tests/.venv/bin/python")

    admission = """
    import json,time
    from mn_sdk.artifact_handoff import publish_input
    print(json.dumps(publish_input({'task':{'task_id':'scan-0001','kind':'source_scan'},'request':{'prompt':'bounded frozen evidence'},'request_hash':'frozen-hash','offline':False,'deadline':time.time()+60,'opencode':{'model':'fake'}},run_id='actual-run')))
    """

    {json, 0} =
      System.cmd(python, ["-c", admission],
        env: [
          {"MN_JOB_SHARED_STORAGE_ROOT", ctx.config["environment"]["MN_JOB_SHARED_STORAGE_ROOT"]}
        ]
      )

    input = Jason.decode!(json)

    script = """
    import sys
    sys.path.insert(0, #{Jason.encode!(Path.expand("../mn-skills/opencode_skill/src"))})
    sys.path.insert(0, #{Jason.encode!(Path.expand("../mn-agents/prototype_stateful_step_agent/src"))})
    from domain.sandbox_review import review_admitted
    from agents import architecture_packet_reviewer as binding
    binding.review_admitted=lambda ref: review_admitted(ref,llm_client=lambda prompt:'{"task_id":"scan-0001","kind":"source_scan","status":"blocked","reason":"deterministic review"}')
    from mn_sdk.step_runtime import main
    main(['--handler','agents.architecture_packet_reviewer'])
    """

    config =
      ctx.config
      |> Map.put(
        "upload_paths",
        for(
          name <- ["domain", "agents"],
          do: %{"source" => Path.join(payloads, name), "target" => name}
        )
      )
      |> Map.put("command", [python, "-c", script])

    work = %{"step_input" => %{"_child" => %{"revision" => 0}, "review_input" => input}}
    assert {:ok, result} = OpenShell.run(work, config, ctx.opts)
    assert result["structured_result"]["outputs"]["task_id"] == "scan-0001"

    assert Enum.any?(
             result["artifact_receipt"]["references"],
             &(&1["kind"] == "architecture_review_result")
           )

    assert Path.wildcard(Path.join(ctx.root, "sandboxes/**/budget.sqlite")) == []
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
