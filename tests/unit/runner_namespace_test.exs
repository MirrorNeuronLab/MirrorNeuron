defmodule MirrorNeuron.RunnerNamespaceTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Runner.DockerCompose
  alias MirrorNeuron.Runner.OpenShell

  test "OpenShell has a runner namespace entrypoint" do
    assert {:module, OpenShell} = Code.ensure_loaded(OpenShell)
    assert function_exported?(OpenShell, :run, 3)
  end

  test "OpenShell runner namespace infers openshell runtime driver" do
    assert ResourceSpec.infer_runtime_driver(%{
             "runner_module" => "MirrorNeuron.Runner.OpenShell"
           }) == "openshell"
  end

  test "DockerCompose has a runner namespace entrypoint and driver" do
    assert {:module, DockerCompose} = Code.ensure_loaded(DockerCompose)
    assert function_exported?(DockerCompose, :run, 3)

    assert ResourceSpec.infer_runtime_driver(%{
             "runner_module" => "MirrorNeuron.Runner.DockerCompose"
           }) == "docker_compose"
  end

  test "runner names resolve without interning arbitrary manifest strings" do
    name = "MirrorNeuron.Runner.Unknown#{System.unique_integer([:positive])}"

    assert {:error, "Unknown runner module"} =
             MirrorNeuron.Runner.run(%{}, %{"runner_module" => name}, job_id: "test")

    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
  end

  test "current OpenShell wire names dispatch to the fenced adapter" do
    for name <- [
          "MirrorNeuron.Runner.OpenShell",
          "Elixir.MirrorNeuron.Runner.OpenShell"
        ] do
      config = %{
        "runner_module" => name,
        "environment" => %{"MN_WORKFLOW_STEP_HANDLER" => "mn_sdk.integrations.block_worker"}
      }

      assert {:error, "OpenShell block workers require artifact_handoff v1"} =
               MirrorNeuron.Runner.run(%{}, config, job_id: "stored")
    end
  end

  test "retired OpenShell namespaces cannot dispatch workers" do
    for name <- ["MirrorNeuron.Sandbox.OpenShell", "Elixir.MirrorNeuron.Sandbox.OpenShell"] do
      assert {:error, "Unknown runner module"} =
               MirrorNeuron.Runner.run(%{}, %{"runner_module" => name}, job_id: "retired")
    end
  end

  test "a non-Compose runner never takes ownership of a Compose record" do
    for name <- ["HostLocal", "DockerWorker", "OpenShell"] do
      config = %{
        "runner_module" => "MirrorNeuron.Runner." <> name,
        "mn_docker_compose" => %{"project_name" => "another-project"}
      }

      assert :ok = MirrorNeuron.Runner.stop_prepared([config], :pause)
      refute MirrorNeuron.Runner.resumable_after_stop?(config)
    end
  end

  test "only a prepared Compose project can start another serving generation after a stop" do
    config = %{"runner_module" => "MirrorNeuron.Runner.DockerCompose"}
    refute MirrorNeuron.Runner.resumable_after_stop?(config)

    assert MirrorNeuron.Runner.resumable_after_stop?(
             Map.put(config, "mn_docker_compose", %{"project_name" => "owned-project"})
           )
  end
end
