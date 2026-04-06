defmodule PatchCluster do
  def run do
    content = File.read!("lib/mirror_neuron/cli/commands/cluster.ex")
    
    new_setup = """
  defp setup_cluster_env(args, role) do
    {opts, _, _} = OptionParser.parse(args, 
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
    seeds = Keyword.get(opts, :join) || Keyword.get(opts, :seeds)

    System.cmd("epmd", ["-daemon"])

    if bind do
      [host | maybe_port] = String.split(bind, ":")
      port = if length(maybe_port) > 0, do: List.first(maybe_port), else: "4370"
      
      System.put_env(
        "ERL_AFLAGS",
        "-connect_all false -kernel inet_dist_listen_min \#{port} inet_dist_listen_max \#{port}"
      )
      
      node_name_host = if host == "0.0.0.0" and not is_nil(node_id), do: node_id, else: host

      if node_id do
        System.put_env("MIRROR_NEURON_NODE_NAME", "\#{node_id}@\#{node_name_host}")
      else
        System.put_env("MIRROR_NEURON_NODE_NAME", "node-\#{System.unique_integer([:positive])}@\#{node_name_host}")
      end
    else
      if role == "control" do
        port = find_free_port(4374)
        System.put_env(
          "ERL_AFLAGS",
          "-connect_all false -kernel inet_dist_listen_min \#{port} inet_dist_listen_max \#{port}"
        )
        System.put_env(
          "MIRROR_NEURON_NODE_NAME",
          "control-\#{System.system_time(:second)}-\#{System.unique_integer([:positive])}@127.0.0.1"
        )
      end
    end

    if seeds do
      cluster_nodes = String.split(seeds, ",")
        |> Enum.map(&parse_seed_to_node_name_string/1)
        |> Enum.join(",")
      System.put_env("MIRROR_NEURON_CLUSTER_NODES", cluster_nodes)
    end

    System.put_env("MIRROR_NEURON_NODE_ROLE", role)
  end
"""
    new_content = String.replace(content, ~r/  defp setup_cluster_env.*?(?=  def run\(\["start")/s, new_setup)
    File.write!("lib/mirror_neuron/cli/commands/cluster.ex", new_content)
  end
end
PatchCluster.run()
