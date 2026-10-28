defmodule MirrorNeuron.BlockEventRunnerTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runner.OpenShell
  alias MirrorNeuron.Builtins.BlockEventResult
  alias MirrorNeuron.Runtime.{WorkflowAdmission, WorkflowLedger}

  @tag :tmp_dir
  test "compiled event blocks keep state across replacement OpenShell sandboxes", %{tmp_dir: root} do
    keys = ~w(MN_SHARED_STORAGE_ROOT FAKE_SANDBOX_ROOT OPENSHELL_GATEWAY_ENDPOINT)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    System.put_env("MN_SHARED_STORAGE_ROOT", root)
    System.put_env("FAKE_SANDBOX_ROOT", Path.join(root, "sandboxes"))
    System.put_env("OPENSHELL_GATEWAY_ENDPOINT", "http://fake.invalid")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    python = System.get_env("MN_TEST_PYTHON") || System.find_executable("python3")
    sdk = System.get_env("MN_TEST_SDK_ROOT") || Path.expand("../mn-python-sdk")
    bundle = Path.join(root, "package")
    calls = Path.join(root, "calls")

    script = """
    import json, sys
    from pathlib import Path
    sys.path.insert(0, #{Jason.encode!(sdk)})
    for package in Path(#{Jason.encode!(sdk)}).glob('packages/*/src'): sys.path.insert(0, str(package))
    from mn_sdk.blueprints import read_blueprint, compile_blueprint
    from mn_sdk.blueprints.authoring import write_blueprint_definition
    from mn_sdk.blueprints.worker_descriptors import resolved_worker_descriptor
    import mn_sdk, mn_sdk_common, mn_blueprint_blocks
    for module in (mn_sdk, mn_sdk_common, mn_blueprint_blocks):
        assert Path(module.__file__).resolve().is_relative_to(Path(#{Jason.encode!(sdk)}).resolve())
    root = Path(#{Jason.encode!(bundle)})
    write_blueprint_definition(root, {
      'apiVersion':'mn.workflow/v1','kind':'WorkflowSource',
      'identity':{'id':'event_demo','name':'Event demo'}, 'intent':{'description':'Synthetic event worker'},
      'defaults':{'worker':{'with':{'image':'python:3.12-slim'}}},
      'workflow':{'steps':[{'id':'seed','needs':[],'run':{'handler':'domain.seed'}}]},
      'agents':{'registry':{},'entrypoints':['monitor'],'extra_nodes':[{
        'node_id':'monitor','type':'generic','agent_type':'executor','config':{'runner_module':'MirrorNeuron.Runner.OpenShell'}}]},
      'packages':[{'name':'mn-blueprint-blocks','type':'pip','source':'gar','version':'>=1.3.61.dev27,<2'}],
      'metadata':{'mn_blocks':{'events':{'monitor':{
        'uses':'mn.blocks.event_processing@1','config':{'ports':{'ready':'sample_ready'},'event_types':['sampled']},
        'hooks':{'process':'domain.events:process'},'limits':{'timeout_seconds':10}}}}}
    }, config={})
    domain = root/'payloads/domain'
    domain.mkdir(parents=True, exist_ok=True)
    (domain/'__init__.py').write_text('')
    (domain/'events.py').write_text('''from pathlib import Path
    from mn_sdk.integrations.block_publication_files import publish_files
    from mn_sdk_common.publication import ArtifactWrite
    def process(context, work):
        assert '/local/runs/actual-run' in str(context.store.run_dir)
        path = Path(#{Jason.encode!(calls)})
        path.write_text(str(int(path.read_text()) + 1) if path.exists() else '1')
        count = work['state'].get('count', 0) + 1
        publication = publish_files(context, [ArtifactWrite('report', 'reports/scene.md', ('# Scene '+str(count)+chr(10)).encode(), kind='markdown')])
        return {'state': {'count': count}, 'outputs': {'count': count, 'published_files': publication},
                'emissions': [{'port':'ready', 'value':{'count':count}}],
                'events': [{'type':'sampled','payload':{'count':count}}]}
    ''')
    package = read_blueprint(root)
    compiled = compile_blueprint(package).manifest
    runtime = root/'payloads/runtime'
    runtime.mkdir()
    (runtime/'manifest.json').write_text(json.dumps(resolved_worker_descriptor(package, compiled)))
    node = next(n for n in compiled['agents']['nodes'] if n['node_id']=='monitor')
    (root/'event-config.json').write_text(json.dumps(node['config']))
    """

    assert {_, 0} = System.cmd(python, ["-c", script], stderr_to_stdout: true)
    config = Jason.decode!(File.read!(Path.join(bundle, "event-config.json")))

    config =
      Map.merge(config, %{
        "sandbox_cli" => Path.expand("tests/handoff/fake_openshell.py"),
        "sandbox_name" => "event-one",
        "reuse_shared_sandbox" => true,
        "artifact_handoff" => %{"version" => "mn.artifact_handoff/v1", "export_outputs" => true},
        "command" => [python, "-m", "mn_sdk.step_runtime"],
        "workdir" => "/sandbox/job",
        "upload_paths" =>
          Enum.map(
            ["domain", "runtime"],
            &%{"source" => Path.join([bundle, "payloads", &1]), "target" => &1}
          )
      })

    pythonpath = Enum.join([".", sdk | Path.wildcard(Path.join(sdk, "packages/*/src"))], ":")

    config =
      update_in(
        config["environment"],
        &Map.merge(&1, %{
          "PYTHONPATH" => pythonpath,
          "MN_SDK_COMPONENTS_JSON" => "[\"blueprint-blocks\"]",
          "MN_JOB_SHARED_STORAGE_ROOT" => Path.join(root, "submission"),
          "MN_JOB_OUTPUT_DIR" => Path.join(root, "submission/outputs/user")
        })
      )

    node = %{node_id: "monitor", agent_type: "executor", config: config}

    manifest = %MirrorNeuron.Manifest{
      type: "service",
      flow: %{"steps" => [%{"id" => "monitor-phase", "run" => "monitor"}]}
    }

    ledger =
      WorkflowLedger.new(manifest, [node], %{"workflow_state" => %{"run_id" => "actual-run"}})

    worker = %{
      node: node,
      coordinator: self(),
      runtime_context: %{workflow_agent_steps: WorkflowLedger.agent_to_step(ledger)}
    }

    message = MirrorNeuron.Message.new("event-job", "source", "monitor", "tick", %{})
    assert {:ok, ^message} = WorkflowAdmission.prepare(message, worker)

    opts = [
      job_id: "event-job",
      run_id: "actual-run",
      agent_id: "monitor",
      step_instance: "event-one",
      attempt: 1,
      lease_epoch: 1,
      lease_validator: fn _, _ -> :ok end,
      message: message
    ]

    assert {:ok, first} = OpenShell.run(%{}, config, opts)
    first_payload = first["structured_result"]
    assert first_payload["outputs"]["count"] == 1
    report = Path.join(root, "submission/outputs/user/reports/scene.md")
    refute File.exists?(report)
    assert {:ok, state, [_], [_]} = BlockEventResult.interpret(first_payload, %{}, config)
    context = %{workflow: %{"run_id" => "actual-run"}}

    assert {:ok, []} =
             MirrorNeuron.Builtins.BlockEventPublication.publish(first_payload, config, context)

    assert File.read!(report) == "# Scene 1\n"
    assert state["handoff"]["version"] == "mn.block_handoff/v1"
    File.rm_rf!(Path.join(root, "sandboxes"))
    assert {:ok, ^first} = OpenShell.run(%{}, config, Keyword.put(opts, :agent_state, state))
    File.rm!(report)

    assert {:ok, []} =
             MirrorNeuron.Builtins.BlockEventPublication.publish(first_payload, config, context)

    assert File.read!(report) == "# Scene 1\n"
    assert File.read!(calls) == "1"

    assert {^ledger, [], []} =
             WorkflowLedger.on_agent_event(
               ledger,
               "monitor",
               :workflow_step_attempt_completed,
               %{"outputs" => %{"count" => 1}}
             )

    next_message = MirrorNeuron.Message.new("event-job", "source", "monitor", "tick", %{})
    assert {:ok, ^next_message} = WorkflowAdmission.prepare(next_message, worker)

    next_opts =
      opts
      |> Keyword.put(:step_instance, "event-two")
      |> Keyword.put(:message, next_message)
      |> Keyword.put(:agent_state, state)

    assert {:ok, second} =
             OpenShell.run(%{}, Map.put(config, "sandbox_name", "event-two"), next_opts)

    assert second["structured_result"]["outputs"]["count"] == 2

    assert {:ok, next_state, [_], [_]} =
             BlockEventResult.interpret(second["structured_result"], state, config)

    assert next_state["reference"] != state["reference"]

    assert {:ok, []} =
             MirrorNeuron.Builtins.BlockEventPublication.publish(
               second["structured_result"],
               config,
               context
             )

    assert File.read!(report) == "# Scene 2\n"
    assert File.read!(calls) == "2"
  end
end
