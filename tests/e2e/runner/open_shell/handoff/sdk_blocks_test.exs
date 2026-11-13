defmodule MirrorNeuron.OpenShellArtifactHandoffTest.SdkBlocksTest do
  use MirrorNeuron.OpenShellHandoffCase, async: false

  alias MirrorNeuron.Runner.OpenShell

  test "stock SDK block binding uses private run storage and verified artifact commits", ctx do
    sdk = Path.expand("../mn-python-sdk")
    domain = Path.join(ctx.root, "domain")
    File.mkdir_p!(domain)
    File.write!(Path.join(domain, "__init__.py"), "")

    File.write!(Path.join(domain, "probe.py"), """
    from pathlib import Path
    def analyze(block, inputs):
        assert '/local/runs/actual-run' in str(block.store.run_dir)
        assert block.environment['MN_JOB_OUTPUT_DIR'] != block.environment['MN_ARTIFACT_OUTPUT_DIR']
        count = Path(#{Jason.encode!(Path.join(ctx.root, "calls"))})
        count.write_text(str(int(count.read_text()) + 1) if count.exists() else '1')
        raw = block.store.commit_bytes('evidence.bin', b'verified bytes')
        from mn_sdk.integrations.block_publication_files import publish_files
        from mn_sdk_common.publication import ArtifactWrite
        publication = publish_files(block, [ArtifactWrite('report', 'reports/review.txt', b'verified report'),
            ArtifactWrite('view', 'views/review.html', b'optional view', required=False)])
        return {'status': 'ready', 'evidence': raw.to_dict(), 'published_files': publication}
    """)

    pythonpath =
      [".", sdk | Path.wildcard(Path.join(sdk, "packages/*/src"))]
      |> Enum.join(":")

    parameters = %{
      "revision" => "probe@1",
      "instance" => %{
        "uses" => "mn.blocks.domain_operation@1",
        "hooks" => %{"operation" => "domain.probe:analyze"}
      }
    }

    config =
      ctx.config
      |> put_in(["artifact_handoff", "export_outputs"], true)
      |> Map.put("upload_paths", [%{"source" => domain, "target" => "domain"}])
      |> Map.put("command", [
        System.get_env("MN_TEST_PYTHON") || System.find_executable("python3"),
        "-m",
        "mn_sdk.step_runtime",
        "--handler",
        "mn_sdk.integrations.block_worker",
        "--with-json",
        Jason.encode!(parameters)
      ])
      |> update_in(
        ["environment"],
        &Map.merge(&1, %{
          "PYTHONPATH" => pythonpath,
          "MN_RUN_DIR" => Path.join(ctx.root, "owner-only"),
          "MN_JOB_OUTPUT_DIR" => Path.join(ctx.root, "submission/outputs/user"),
          "MN_SDK_COMPONENTS_JSON" => "[\"blueprint-blocks\"]"
        })
      )

    message =
      MirrorNeuron.Message.new("handoff-test", "runtime", "generate", "init", %{},
        headers: %{
          "mn.workflow.step_id" => "generate",
          "mn.workflow.idempotency_key" => "actual-run/generate"
        }
      )

    opts = Keyword.put(ctx.opts, :message, message)

    File.mkdir_p!(Path.join(ctx.root, "submission/outputs/user"))
    File.write!(Path.join(ctx.root, "submission/outputs/user/views"), "blocks optional directory")

    assert {:ok, result} = OpenShell.run(%{}, config, opts)
    bundle = result["structured_result"]["outputs"]["result"]
    assert bundle["version"] == "mn.block_handoff/v1"
    assert length(bundle["files"]) == 5
    assert length(result["artifact_receipt"]["references"]) == 5
    assert [%{"artifact_id" => "views/review.html"}] = result["export_warnings"]
    report = Path.join(ctx.root, "submission/outputs/user/reports/review.txt")
    assert File.read!(report) == "verified report"
    refute File.exists?(Path.join(ctx.root, "owner-only"))
    File.rm_rf!(Path.join(ctx.root, "sandboxes"))
    File.rm!(report)
    File.rm!(Path.join(ctx.root, "submission/outputs/user/views"))
    assert {:ok, replayed} = OpenShell.run(%{}, config, opts)
    assert replayed["structured_result"] == result["structured_result"]
    assert replayed["artifact_receipt"] == result["artifact_receipt"]
    refute Map.has_key?(replayed, "export_warnings")
    assert File.read!(report) == "verified report"

    assert File.read!(Path.join(ctx.root, "submission/outputs/user/views/review.html")) ==
             "optional view"

    assert File.read!(Path.join(ctx.root, "calls")) == "1"
  end

  test "canonical stock block discovers its compiled descriptor in the private invocation", ctx do
    sdk = Path.expand("../mn-python-sdk")
    python = System.get_env("MN_TEST_PYTHON") || System.find_executable("python3")

    pythonpath =
      [".", sdk | Path.wildcard(Path.join(sdk, "packages/*/src"))]
      |> Enum.join(":")

    source = Path.join(ctx.root, "source")

    script = """
    import json
    from pathlib import Path
    from mn_sdk.blueprints import compile_blueprint, read_blueprint
    from mn_sdk.blueprints.authoring import write_blueprint_definition
    from mn_sdk.blueprints.worker_descriptors import resolved_worker_descriptor, stage_worker_descriptor_uploads
    root = Path(#{Jason.encode!(source)})
    write_blueprint_definition(root, {
        'apiVersion': 'mn.workflow/v1', 'kind': 'WorkflowSource',
        'identity': {'id': 'canonical_probe', 'name': 'Canonical probe'},
        'intent': {'description': 'Canonical private descriptor verification'},
        'workflow': {'steps': [{'id': 'generate', 'needs': []}]},
        'agents': {'registry': {}},
        'defaults': {'worker': {'with': {'image': 'python:3.12-slim'}}},
        'packages': [{'name': 'mn-blueprint-blocks', 'type': 'pip', 'source': 'gar', 'version': '>=1.3.61.dev26,<2'}],
        'metadata': {'mn_blocks': {'steps': {'generate': {
            'uses': 'mn.blocks.domain_operation@1', 'hooks': {'operation': 'domain.probe:analyze'}
        }}}}
    }, config={'selected': 'private compiled descriptor'})
    domain = root / 'payloads/domain'
    domain.mkdir(parents=True)
    (domain / 'probe.py').write_text('''import os
    from pathlib import Path
    from mn_sdk.blueprint_support import source_manifest
    def analyze(block, inputs):
        assert source_manifest(__file__)['identity']['id'] == 'canonical_probe'
        assert block.config['selected'] == 'private compiled descriptor'
        assert Path(os.environ['MN_BLUEPRINT_MANIFEST_PATH']).is_relative_to(os.environ['MN_BUNDLE_ROOT'])
        count = Path(#{Jason.encode!(Path.join(ctx.root, "calls"))})
        count.write_text(str(int(count.read_text()) + 1) if count.exists() else '1')
        return {'status': 'compiled descriptor loaded'}
    ''')
    package = read_blueprint(root)
    manifest = compile_blueprint(package).manifest
    node = next(n for n in manifest['agents']['nodes'] if n.get('config', {}).get('environment', {}).get('MN_WORKFLOW_STEP_HANDLER') == 'mn_sdk.integrations.block_worker')
    config = node['config']
    config['runner_module'] = 'MirrorNeuron.Runner.OpenShell'
    config['upload_paths'] = [{'source': 'domain', 'target': 'domain'}]
    payloads = {'runtime/manifest.json': json.dumps(resolved_worker_descriptor(package, manifest)).encode()}
    stage_worker_descriptor_uploads(manifest, payloads)
    descriptor = root / 'payloads/runtime/manifest.json'
    descriptor.parent.mkdir()
    descriptor.write_bytes(payloads['runtime/manifest.json'])
    print(json.dumps({'parameters': json.loads(config['environment']['MN_WORKFLOW_STEP_WITH_JSON']),
        'uploads': [{'source': str(root / 'payloads' / u['source']), 'target': u['target']} for u in config['upload_paths']]}))
    """

    {output, status} =
      System.cmd(python, ["-c", script],
        env: [{"PYTHONPATH", pythonpath}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    prepared = Jason.decode!(output)

    config =
      ctx.config
      |> Map.put("upload_paths", prepared["uploads"])
      |> Map.put("command", [
        python,
        "-m",
        "mn_sdk.step_runtime",
        "--handler",
        "mn_sdk.integrations.block_worker",
        "--with-json",
        Jason.encode!(prepared["parameters"])
      ])
      |> update_in(
        ["environment"],
        &Map.merge(&1, %{
          "PYTHONPATH" => pythonpath,
          "MN_BUNDLE_ROOT" => Path.join(ctx.root, "owner-only"),
          "MN_BLUEPRINT_MANIFEST_PATH" => Path.join(ctx.root, "owner-only/manifest.json"),
          "MN_BLUEPRINT_CONFIG_JSON" => "{\"selected\":\"private compiled descriptor\"}",
          "MN_SDK_COMPONENTS_JSON" => "[\"blueprint-blocks\"]"
        })
      )

    message =
      MirrorNeuron.Message.new("handoff-test", "runtime", "generate", "init", %{},
        headers: %{
          "mn.workflow.step_id" => "generate",
          "mn.workflow.idempotency_key" => "actual-run/generate"
        }
      )

    opts = Keyword.put(ctx.opts, :message, message)
    assert {:ok, result} = OpenShell.run(%{}, config, opts)
    assert result["phase"] == "committed"
    assert result["structured_result"]["outputs"]["result"]["version"] == "mn.block_handoff/v1"
    File.rm_rf!(Path.join(ctx.root, "sandboxes"))
    assert {:ok, ^result} = OpenShell.run(%{}, config, opts)
    assert File.read!(Path.join(ctx.root, "calls")) == "1"
  end

  test "code-generation blueprint uses committed references and exports verified HTML", ctx do
    demo = Path.expand("../../mn-blueprints/demo_openshell_code_generation", File.cwd!())
    python = System.get_env("MN_TEST_PYTHON") || System.find_executable("python3")

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

  test "stock block resolves immutable admission without an owner ledger in sandbox", ctx do
    domain = Path.join(ctx.root, "domain")
    File.mkdir_p!(domain)
    File.write!(Path.join(domain, "__init__.py"), "")

    File.write!(Path.join(domain, "admission.py"), """
    import json
    from mn_sdk.artifact_handoff import resolve_input
    def review(block, inputs):
        block.check()
        frozen = json.loads(resolve_input(inputs['review_input']).read_text())
        assert frozen['request'] == {'prompt': 'bounded frozen evidence'}
        assert not list(block.store.run_dir.rglob('budget.sqlite'))
        return {'request_hash': frozen['request_hash'], 'status': 'reviewed'}
    """)

    python = System.get_env("MN_TEST_PYTHON") || System.find_executable("python3")

    admission = """
    import json
    from mn_sdk.artifact_handoff import publish_input
    print(json.dumps(publish_input({'request':{'prompt':'bounded frozen evidence'},'request_hash':'frozen-hash'},run_id='actual-run')))
    """

    {json, 0} =
      System.cmd(python, ["-c", admission],
        env: [
          {"MN_JOB_SHARED_STORAGE_ROOT", ctx.config["environment"]["MN_JOB_SHARED_STORAGE_ROOT"]}
        ]
      )

    input = Jason.decode!(json)

    script = """
    import sys,os,json
    from dataclasses import asdict,replace
    from pathlib import Path
    sdk=Path(#{Jason.encode!(Path.expand("../mn-python-sdk"))})
    for p in sdk.glob('packages/*/src'): sys.path.insert(0,str(p))
    from mn_sdk.integrations.block_worker import run
    from mn_sdk.step_runtime import StepContext
    os.environ['MN_SDK_COMPONENTS_JSON']='["blueprint-blocks"]'
    context=replace(StepContext.from_environment(),idempotency_key='actual-run/review',step_id='review')
    result=run(context,revision='probe@1',instance={'uses':'mn.blocks.domain_operation@1',
        'hooks':{'operation':'domain.admission:review'}})
    print(json.dumps(asdict(result)))
    """

    config =
      ctx.config
      |> Map.put("upload_paths", [%{"source" => domain, "target" => "domain"}])
      |> Map.put("command", [python, "-c", script])

    work = %{"step_input" => %{"_child" => %{"revision" => 0}, "review_input" => input}}
    assert {:ok, result} = OpenShell.run(work, config, ctx.opts)
    assert result["structured_result"]["outputs"]["result"]["version"] == "mn.block_handoff/v1"

    assert Enum.any?(
             result["artifact_receipt"]["references"],
             &(&1["kind"] == "block_artifact")
           )

    assert Path.wildcard(Path.join(ctx.root, "sandboxes/**/budget.sqlite")) == []
  end
end
