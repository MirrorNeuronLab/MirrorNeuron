defmodule MirrorNeuron.Cluster.FederationRegistry.Storage do
  @moduledoc "Serializes private peer registry updates and atomically replaces its file."

  @registry_version 1

  def update_registry(callback) do
    :global.trans({{MirrorNeuron.Cluster.FederationRegistry, registry_path()}, self()}, fn ->
      peers = read_registry()

      case callback.(peers) do
        {:ok, updated, value, status} ->
          with :ok <- write_registry(updated), do: {:ok, value, status}

        error ->
          error
      end
    end)
  end

  def read_registry do
    case File.read(registry_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"peers" => peers}} when is_map(peers) -> peers
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_registry(peers) do
    path = registry_path()
    directory = Path.dirname(path)
    temp = path <> ".tmp"

    peers =
      Map.new(peers, fn {node_name, peer} ->
        {node_name, Map.drop(peer, ["job_projections", "run_projections"])}
      end)

    with :ok <- File.mkdir_p(directory),
         :ok <-
           File.write(temp, Jason.encode!(%{"version" => @registry_version, "peers" => peers})),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp registry_path do
    home =
      case System.get_env("MN_HOME") do
        value when is_binary(value) and value != "" -> value
        _ -> Path.join(System.user_home!(), ".mn")
      end

    Path.join([home, "federation", "peers.json"])
  end
end
