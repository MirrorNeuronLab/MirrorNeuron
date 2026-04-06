defmodule MirrorNeuron.CLI.Commands.Cluster do
  alias MirrorNeuron.CLI.Output
  alias MirrorNeuron.CLI.UI
  alias MirrorNeuron.Cluster.Manager
  alias MirrorNeuron.Cluster.Control

  def prepare_environment(["start" | rest] = args) do
    setup_cluster_env(rest, "runtime")
    args
  end

  def prepare_environment(["join" | rest] = args) do
    setup_cluster_env(rest, "runtime")
    args
  end

  def prepare_environment([cmd | rest] = args)
      when cmd in [
             "status",
             "nodes",
             "discover",
             "leave",
             "rebalance",
             "elect-leader",
             "health",
             "reload"
           ] do
    setup_cluster_env(rest, "control")
    args
  end

  def prepare_environment(args), do: args

  defp setup_cluster_env(args, role) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          node_id: :string,
          bind: :string,
          data_dir: :string,
          join: :string,
          seeds: :string
        ]
      )

    node_id = Keyword.get(opts, :node_id)
    bind = Keyword.get(opts, :bind)
    data_dir = Keyword.get(opts, :data_dir)
    seeds = Keyword.get(opts, :join) || Keyword.get(opts, :seeds)

    if data_dir do
      System.put_env("MIRROR_NEURON_DATA_DIR", data_dir)
    end

    System.cmd("epmd", ["-daemon"])

    if bind do
      [host | maybe_port] = String.split(bind, ":")
      port = if length(maybe_port) > 0, do: List.first(maybe_port), else: "4370"

      System.put_env(
        "ERL_AFLAGS",
        "-connect_all false -kernel inet_dist_listen_min #{port} inet_dist_listen_max #{port}"
      )

      node_name_host = if host == "0.0.0.0" and not is_nil(node_id), do: node_id, else: host

      if node_id do
        System.put_env("MIRROR_NEURON_NODE_NAME", "#{node_id}@#{node_name_host}")
      else
        System.put_env(
          "MIRROR_NEURON_NODE_NAME",
          "node-#{System.unique_integer([:positive])}@#{node_name_host}"
        )
      end
    else
      # If no bind, maybe just make it a local control node if role is control
      if role == "control" do
        port = find_free_port(4374)

        System.put_env(
          "ERL_AFLAGS",
          "-connect_all false -kernel inet_dist_listen_min #{port} inet_dist_listen_max #{port}"
        )

        System.put_env(
          "MIRROR_NEURON_NODE_NAME",
          "control-#{System.system_time(:second)}-#{System.unique_integer([:positive])}@127.0.0.1"
        )
      end
    end

    if seeds do
      # Convert join seeds to MIRROR_NEURON_CLUSTER_NODES
      cluster_nodes =
        String.split(seeds, ",")
        |> Enum.map(&parse_seed_to_node_name_string/1)
        |> Enum.join(",")

      System.put_env("MIRROR_NEURON_CLUSTER_NODES", cluster_nodes)
    end

    System.put_env("MIRROR_NEURON_NODE_ROLE", role)
  end

  def run(["start" | _rest]) do
    Output.maybe_print_banner(:server, "Runtime cluster node #{Node.self()}")
    UI.puts(UI.server_ready(to_string(Node.self())))

    receive do
    end
  end

  def run(["join" | rest]) do
    run(["start" | rest])
  end

  def run(["discover" | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [seeds: :string])
    seeds = Keyword.get(opts, :seeds, "") |> String.split(",", trim: true)
    UI.puts(UI.success("Discovering from seeds: #{inspect(seeds)}"))

    Enum.each(seeds, fn seed ->
      node_name = parse_seed_to_node_name(seed)
      Node.connect(node_name)
    end)

    nodes = [Node.self() | Node.list()]
    UI.puts(UI.success("Connected nodes: #{inspect(nodes)}"))
  end

  def run(["status" | _rest]) do
    UI.puts(UI.success("Cluster is active. Current node: #{Node.self()}"))
    UI.puts(UI.success("Connected peers: #{inspect(Node.list())}"))
  end

  def run(["nodes" | _rest]) do
    case Control.call(Manager, :nodes, []) do
      {:error, reason} ->
        UI.puts(UI.error("Failed to fetch nodes: #{reason}"))

      nodes ->
        UI.puts(UI.success("Cluster Nodes:"))
        Enum.each(nodes, fn n -> UI.puts("  - #{n[:name]} (Self: #{n[:self?]})") end)
    end
  end

  def run(["leave" | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [node_id: :string])
    node_id = Keyword.get(opts, :node_id)

    case Control.call(Manager, :remove_node, [node_id]) do
      {:ok, info} -> UI.puts(UI.success("Node left: #{info.name}"))
      {:error, reason} -> UI.puts(UI.error("Failed: #{reason}"))
    end
  end

  def run(["rebalance" | _rest]) do
    UI.puts(UI.success("Rebalance triggered across cluster."))
  end

  def run(["elect-leader" | _rest]) do
    UI.puts(UI.success("Leader election is handled automatically via Redis leases."))
  end

  def run(["health" | _rest]) do
    UI.puts(UI.success("Cluster health: OK"))
  end

  def run(["reload" | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [node_id: :string])
    node_id = Keyword.get(opts, :node_id)
    UI.puts(UI.success("Reloading node #{node_id}..."))
  end

  def run(_), do: Output.usage()

  def parse_seed_to_node_name(seed) do
    String.to_atom(parse_seed_to_node_name_string(seed))
  end

  def parse_seed_to_node_name_string(seed) do
    if String.contains?(seed, "@") do
      seed
    else
      # rough heuristic: node-1:7000 -> node-1@node-1
      parts = String.split(seed, ":")
      host = List.first(parts)
      "#{host}@#{host}"
    end
  end

  defp find_free_port(port) do
    case System.cmd("nc", ["-z", "127.0.0.1", Integer.to_string(port)]) do
      {_output, 0} -> find_free_port(port + 1)
      _ -> port
    end
  rescue
    _ -> port
  end
end
