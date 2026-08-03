defmodule MirrorNeuron.ServiceSpecTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ServiceSpec

  test "resolves an agent service port from its scheduler allocation" do
    node = %{
      node_id: "mcp_server",
      config: %{"environment" => %{"EXISTING" => "value"}},
      services: [
        %{
          "name" => "mn-job-collaboration",
          "port" => "${env.MN_PORT_MCP_COLLABORATION}",
          "meta" => %{
            "job_id" => "${env.MN_JOB_ID}",
            "run_id" => "${env.MN_RUN_ID}"
          },
          "checks" => [
            %{
              "name" => "tcp-ready",
              "type" => "tcp",
              "port" => "${service.port}"
            }
          ]
        }
      ]
    }

    [service] =
      ServiceSpec.service_instances_for_agent(
        %{services: [], nodes: [node]},
        "job-1",
        node,
        "runtime@local",
        env: %{"MN_JOB_ID" => "stable-job-1", "MN_RUN_ID" => "run-1"},
        allocation: %{
          "ports" => [
            %{"label" => "mcp-collaboration", "port" => 49_152, "protocol" => "http"}
          ]
        }
      )

    assert service["port"] == 49_152
    assert get_in(service, ["checks", Access.at(0), "port"]) == "49152"
    assert service["job_id"] == "job-1"
    assert service["agent_id"] == "mcp_server"
    assert service["meta"]["job_id"] == "stable-job-1"
    assert service["meta"]["run_id"] == "run-1"
  end
end
