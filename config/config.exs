import Config

parse_positive_integer = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _ -> default
      end
  end
end

executor_default_concurrency =
  parse_positive_integer.("MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY", 4)

executor_pool_capacities =
  "MIRROR_NEURON_EXECUTOR_POOL_CAPACITIES"
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.reduce(%{"default" => executor_default_concurrency}, fn entry, acc ->
    case String.split(entry, "=", parts: 2) do
      [pool, raw_capacity] ->
        case Integer.parse(raw_capacity) do
          {capacity, ""} when capacity > 0 -> Map.put(acc, pool, capacity)
          _ -> acc
        end

      _ ->
        acc
    end
  end)

cluster_hosts =
  "MIRROR_NEURON_CLUSTER_NODES"
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

topologies =
  if cluster_hosts == [] do
    []
  else
    [
      mirror_neuron: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: cluster_hosts]
      ]
    ]
  end

config :libcluster, topologies: topologies

config :mirror_neuron,
  supported_recovery_modes: ["local_restart", "cluster_recover", "manual_recover"],
  redis_url: System.get_env("MIRROR_NEURON_REDIS_URL", "redis://127.0.0.1:6379/0"),
  redis_namespace: System.get_env("MIRROR_NEURON_REDIS_NAMESPACE", "mirror_neuron"),
  executor_pool_capacities: executor_pool_capacities
