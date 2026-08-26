defmodule MirrorNeuron.Runtime.StableJobTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.StableJob

  test "prepares every execution with authoritative stable and run identity" do
    previous_run_id = "bootstrap-run"

    assert {:ok, manifest} =
             Manifest.load(%{
               "apiVersion" => "mn.workflow/v1",
               "kind" => "Workflow",
               "manifest_version" => "1.0",
               "graph_id" => "stable-job-test",
               "entrypoints" => ["worker"],
               "metadata" => %{
                 "blueprint_run_id" => previous_run_id,
                 "run_id" => previous_run_id,
                 "mn_storage" => %{
                   "input_source_path" => "/inputs/#{previous_run_id}",
                   "output_copy" => [
                     %{
                       "source_path" => "/outputs/#{previous_run_id}",
                       "target_path" => "/runs/#{previous_run_id}"
                     }
                   ]
                 }
               },
               "flow" => %{
                 "nodes" => [
                   %{
                     "node_id" => "worker",
                     "agent_type" => "router",
                     "role" => "root",
                     "config" => %{
                       "job_data_access" => "read_write",
                       "environment" => %{
                         "MN_RUN_ID" => previous_run_id,
                         "MN_RUN_DIR" => "/runs/#{previous_run_id}",
                         "MN_STORAGE_SUBMISSION_ID" => "definition-#{previous_run_id}",
                         "docker_worker_container_name" => "worker-#{previous_run_id}",
                         "MN_BLUEPRINT_CONFIG_JSON" =>
                           Jason.encode!(%{
                             "identity" => %{"run_id" => previous_run_id},
                             "submission_id" => "definition-#{previous_run_id}",
                             "container_name" => "worker-#{previous_run_id}",
                             "source_path" => "/runs/#{previous_run_id}",
                             "mode" => "default"
                           })
                       }
                     }
                   }
                 ],
                 "edges" => []
               }
             })

    definition = %{
      "job_id" => "stable-job",
      "data_generation" => 4,
      "resolved_configuration" => %{"mode" => "safe", "threshold" => 2}
    }

    assert {:ok, prepared} =
             StableJob.prepare_run_manifest(
               manifest,
               definition,
               "run-2",
               "/job-data/stable-job",
               "read",
               inputs: %{"identity" => %{"job_id" => "forged", "run_id" => "forged"}}
             )

    prepared_map = Manifest.to_map(prepared)
    [node] = get_in(prepared_map, ["flow", "nodes"])
    environment = get_in(node, ["config", "environment"])
    config = Jason.decode!(environment["MN_BLUEPRINT_CONFIG_JSON"])

    assert get_in(prepared_map, ["metadata", "job_id"]) == "stable-job"
    assert get_in(prepared_map, ["metadata", "run_id"]) == "run-2"

    assert get_in(prepared_map, ["metadata", "mn_storage", "input_source_path"]) ==
             "/inputs/bootstrap-run"

    assert get_in(prepared_map, [
             "metadata",
             "mn_storage",
             "output_copy",
             Access.at(0),
             "source_path"
           ]) == "/outputs/run-2"

    assert environment["MN_JOB_ID"] == "stable-job"
    assert environment["MN_RUN_ID"] == "run-2"
    assert environment["MN_RUN_DIR"] == "/runs/run-2"
    assert environment["MN_STORAGE_SUBMISSION_ID"] == "definition-bootstrap-run"
    assert environment["docker_worker_container_name"] == "worker-bootstrap-run"
    assert environment["MN_JOB_DATA_ACCESS"] == "read"

    assert config == %{
             "identity" => %{"job_id" => "stable-job", "run_id" => "run-2"},
             "submission_id" => "definition-bootstrap-run",
             "container_name" => "worker-bootstrap-run",
             "source_path" => "/runs/bootstrap-run",
             "mode" => "safe",
             "threshold" => 2
           }

    assert get_in(prepared.initial_inputs, ["identity", "job_id"]) == "stable-job"
    assert get_in(prepared.initial_inputs, ["identity", "run_id"]) == "run-2"
  end
end
