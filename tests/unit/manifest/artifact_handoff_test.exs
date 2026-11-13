defmodule MirrorNeuron.ManifestArtifactHandoffTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest

  @handlers ["mn_sdk.integrations.block_worker", "mn_sdk.integrations.block_auxiliary"]
  @openshell ["MirrorNeuron.Runner.OpenShell", "MirrorNeuron.Sandbox.OpenShell"]

  test "Docker and HostLocal block workers do not require OpenShell handoff" do
    for runner <- ["MirrorNeuron.Runner.DockerWorker", "MirrorNeuron.Runner.HostLocal", nil],
        handler <- @handlers do
      assert {:ok, _} = Manifest.load(manifest(runner, handler))
    end
  end

  test "only explicitly selected OpenShell block workers require handoff" do
    for runner <- @openshell, handler <- @handlers do
      assert {:error, errors} = Manifest.load(manifest(runner, handler))
      assert "worker: OpenShell block workers require artifact_handoff v1" in errors

      assert {:ok, _} =
               manifest(runner, handler)
               |> put_in(["flow", "nodes", Access.at(0), "config", "artifact_handoff"], %{
                 "version" => "mn.artifact_handoff/v1"
               })
               |> Manifest.load()
    end
  end

  test "other runners do not invoke OpenShell-specific policy validation" do
    for runner <- ["MirrorNeuron.Runner.DockerWorker", "MirrorNeuron.Runner.HostLocal"] do
      assert {:ok, _} =
               manifest(runner, hd(@handlers))
               |> put_in(["flow", "nodes", Access.at(0), "config", "artifact_handoff"], %{
                 "version" => "future"
               })
               |> Manifest.load()
    end
  end

  test "selected OpenShell workers still reject invalid handoff policies" do
    for runner <- @openshell,
        policy <- [
          %{"version" => "future"},
          %{"version" => "mn.artifact_handoff/v1", "max_files" => 0},
          %{"version" => "mn.artifact_handoff/v1", "export_outputs" => "true"}
        ] do
      assert {:error, _} =
               manifest(runner, hd(@handlers))
               |> put_in(["flow", "nodes", Access.at(0), "config", "artifact_handoff"], policy)
               |> Manifest.load()
    end
  end

  defp manifest(runner, handler) do
    config = %{"environment" => %{"MN_WORKFLOW_STEP_HANDLER" => handler}}
    config = if runner, do: Map.put(config, "runner_module", runner), else: config

    %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "block-runner-validation",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "type" => "generic",
            "config" => config
          }
        ],
        "edges" => []
      }
    }
  end
end
