defmodule MirrorNeuron.Cluster.FederatedServicesTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.FederatedServices

  defmodule LocalRegistry do
    def list(opts) do
      services = [%{"id" => "local", "node" => "node@local"}]

      case Keyword.get(opts, :node) do
        node when node in [nil, "", "node@local"] -> {:ok, services}
        _node -> {:ok, []}
      end
    end
  end

  defmodule FederationRegistry do
    def list do
      [
        %{"node_name" => "node@remote"},
        %{"node_name" => "node@offline"}
      ]
    end
  end

  defmodule FederationClient do
    def list_services("node@remote", opts) do
      send(self(), {:remote_query, opts})

      [
        %{"id" => "remote", "node" => "node@remote"},
        %{"id" => "local", "node" => "node@remote"}
      ]
    end

    def list_services("node@offline", _opts), do: raise("peer unavailable")
  end

  @dependencies [
    local_registry: LocalRegistry,
    federation_registry: FederationRegistry,
    federation_client: FederationClient
  ]

  test "merges matching federated services and tolerates an unavailable peer" do
    assert FederatedServices.list([job_id: "job-1", passing_only: false], @dependencies) ==
             {:ok,
              [
                %{"id" => "local", "node" => "node@local"},
                %{"id" => "remote", "node" => "node@remote"}
              ]}

    assert_received {:remote_query, [job_id: "job-1", passing_only: false]}
  end

  test "queries only the requested federated node" do
    assert FederatedServices.list([node: "node@remote"], @dependencies) ==
             {:ok,
              [
                %{"id" => "remote", "node" => "node@remote"},
                %{"id" => "local", "node" => "node@remote"}
              ]}

    assert_received {:remote_query, [node: "node@remote"]}

    assert FederatedServices.list([node: "node@elsewhere"], @dependencies) ==
             {:ok, []}
  end
end
