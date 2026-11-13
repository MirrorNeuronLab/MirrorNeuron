defmodule MirrorNeuron.Runner.OpenShell.WorkspaceTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runner.OpenShell

  setup do
    root = Path.join(System.tmp_dir!(), "open-shell-stage-#{System.unique_integer([:positive])}")
    previous = System.get_env("MN_TEMP_DIR")
    File.mkdir_p!(root)
    System.put_env("MN_TEMP_DIR", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_TEMP_DIR", previous),
        else: System.delete_env("MN_TEMP_DIR")

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "a staging error removes the invocation's temporary directory", %{root: root} do
    assert {:error, _} =
             OpenShell.stage_workspace(%{}, %{"upload_path" => "/missing-stage-source"},
               job_id: "job",
               agent_id: "worker"
             )

    assert File.ls!(root) == []
  end

  test "exceptions from malformed upload declarations also remove partial staging", %{root: root} do
    assert {:error, _} =
             OpenShell.stage_workspace(%{}, %{"upload_paths" => [%{}]},
               job_id: "job",
               agent_id: "worker"
             )

    assert File.ls!(root) == []
  end

  test "successful staging retains the message and supervision files for the caller", %{
    root: root
  } do
    assert {:ok, dir} =
             OpenShell.stage_workspace(%{"value" => "input"}, %{},
               job_id: "job",
               agent_id: "worker"
             )

    assert String.starts_with?(dir, root <> "/")
    assert File.regular?(Path.join(dir, "mirror_neuron_supervision.py"))

    assert Jason.decode!(File.read!(Path.join(dir, "mirror_neuron_input.json"))) == %{
             "value" => "input"
           }

    assert File.read!(Path.join(dir, "mirror_neuron_body.bin")) != ""
  end

  test "failed sandbox ownership registration removes completed local staging", %{root: root} do
    key = :native_sdk_grpc_native_resource_client
    previous = Application.fetch_env!(:mirror_neuron, key)
    Application.put_env(:mirror_neuron, key, fn _, _, _ -> {:error, "unavailable"} end)
    on_exit(fn -> Application.put_env(:mirror_neuron, key, previous) end)

    config = %{
      "reuse_shared_sandbox" => false,
      "sandbox_cli" => "/missing/cli",
      "command" => ["true"]
    }

    assert {:error, reason} = OpenShell.run(%{}, config, job_id: "job", agent_id: "worker")
    assert reason =~ "ownership"
    assert File.ls!(root) == []
  end
end
