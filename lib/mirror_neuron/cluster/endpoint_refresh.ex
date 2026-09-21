defmodule MirrorNeuron.Cluster.EndpointRefresh do
  @moduledoc "Applies host-owned endpoint updates without changing the BEAM identity."
  alias MirrorNeuron.Cluster.NodeAdapter

  def refresh do
    home = System.get_env("MN_HOME") || Path.expand("~/.mn")

    with {:ok, json} <- File.read(Path.join(home, "runtime-network.json")),
         {:ok, record} <- Jason.decode(json),
         true <- valid?(record, to_string(NodeAdapter.self())) do
      host = record["host"]
      previous = System.get_env("MN_NETWORK_ADVERTISE_HOST")

      if host != previous or
           to_string(record["grpc_port"]) != System.get_env("MN_GRPC_ADVERTISE_PORT") do
        for key <- ["MN_NATIVE_SDK_GRPC_ADVERTISE_HOST", "MN_LITELLM_ADVERTISE_HOST"] do
          if System.get_env(key) in [nil, "", previous], do: System.put_env(key, host)
        end

        if url = System.get_env("MN_ARTIFACT_ADVERTISE_URL") do
          uri = URI.parse(url)

          if uri.host == previous,
            do: System.put_env("MN_ARTIFACT_ADVERTISE_URL", URI.to_string(%{uri | host: host}))
        end

        System.put_env("MN_NETWORK_ADVERTISE_HOST", host)
        System.put_env("MN_GRPC_ADVERTISE_PORT", to_string(record["grpc_port"]))
        info = MirrorNeuron.Grpc.Handlers.ClusterHandshake.node_advertisement_info()

        MirrorNeuron.Cluster.NodeState.advertise_self(
          "healthy",
          Map.put(info, "connection_mode", "local")
        )
      end

      :ok
    else
      _ -> :ignored
    end
  end

  def valid?(
        %{"version" => 1, "node_name" => name, "host" => host, "grpc_port" => port},
        expected
      )
      when is_binary(host) and is_integer(port) do
    name == expected and port in 1..65_535 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/, host)
  end

  def valid?(_, _), do: false
end
