defmodule MirrorNeuron.Runtime.DeploymentPolicyTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.DeploymentPolicy

  test "normalizes Nomad-style rolling defaults" do
    {:ok, manifest} = Manifest.load(manifest())

    policy = DeploymentPolicy.normalize(manifest, %{})

    assert policy["strategy"] == "rolling"
    assert policy["max_parallel"] == 1
    assert policy["canary"] == 0
    assert policy["min_healthy_ms"] == 10_000
    assert policy["healthy_deadline_ms"] == 300_000
    assert policy["progress_deadline_ms"] == 600_000
    assert policy["auto_promote"] == false
    assert policy["auto_revert"] == false
  end

  test "policy overrides can request manual canary deployment" do
    {:ok, manifest} =
      manifest(%{
        "deployment" => %{"key" => "agent-api"},
        "policies" => %{
          "recovery_mode" => "local_restart",
          "update" => %{
            "strategy" => "canary",
            "canary" => 1,
            "max_parallel" => 2,
            "min_healthy_ms" => 0
          }
        }
      })
      |> Manifest.load()

    policy = DeploymentPolicy.normalize(manifest, %{"auto_revert" => true})

    assert DeploymentPolicy.deployment_key(manifest) == "agent-api"
    assert policy["strategy"] == "canary"
    assert policy["canary"] == 1
    assert policy["max_parallel"] == 2
    assert policy["min_healthy_ms"] == 0
    assert policy["auto_revert"] == true
  end

  test "manifest validation rejects malformed update policy" do
    assert {:error, errors} =
             manifest(%{
               "policies" => %{
                 "recovery_mode" => "local_restart",
                 "update" => %{
                   "strategy" => "teleport",
                   "max_parallel" => -1,
                   "auto_promote" => "yes"
                 }
               }
             })
             |> Manifest.load()

    assert Enum.any?(errors, &String.contains?(&1, "policies.update.strategy"))
    assert Enum.any?(errors, &String.contains?(&1, "policies.update.max_parallel"))
    assert Enum.any?(errors, &String.contains?(&1, "policies.update.auto_promote"))
  end

  defp manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "apiVersion" => "mn.workflow/v2",
        "manifest_version" => "1.0",
        "graph_id" => "deploy-policy-test",
        "entrypoints" => ["worker"],
        "flow" => %{
          "nodes" => [
            %{
              "node_id" => "worker",
              "agent_type" => "executor",
              "role" => "root"
            }
          ],
          "edges" => []
        },
        "policies" => %{"recovery_mode" => "local_restart"}
      },
      overrides
    )
  end
end
