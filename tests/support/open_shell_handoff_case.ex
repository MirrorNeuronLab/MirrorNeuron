defmodule MirrorNeuron.OpenShellHandoffCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.OpenShellHandoffCase
    end
  end

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
      "command" => [
        System.get_env("MN_TEST_PYTHON") || System.find_executable("python3"),
        "worker.py"
      ],
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
end
