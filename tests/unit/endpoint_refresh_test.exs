defmodule MirrorNeuron.Cluster.EndpointRefreshTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Cluster.{EndpointRefresh, FederationMonitor}

  test "endpoint changes are bound to the persistent node identity" do
    record = %{
      "version" => 1,
      "node_name" => "a@127.0.0.1",
      "host" => "mini.local",
      "grpc_port" => 55_051
    }

    assert EndpointRefresh.valid?(record, "a@127.0.0.1")
    assert EndpointRefresh.valid?(Map.put(record, "host", "10.0.4.28"), "a@127.0.0.1")
    refute EndpointRefresh.valid?(record, "b@127.0.0.1")
    refute EndpointRefresh.valid?(Map.put(record, "host", "bad\nhost"), "a@127.0.0.1")
    refute EndpointRefresh.valid?(Map.put(record, "grpc_port", 0), "a@127.0.0.1")
    refute EndpointRefresh.valid?(Map.put(record, "version", 2), "a@127.0.0.1")
  end

  test "peer retry delay increases and is capped" do
    assert Enum.map(0..5, &FederationMonitor.retry_delay/1) == [
             5_000,
             10_000,
             20_000,
             40_000,
             60_000,
             60_000
           ]
  end
end
