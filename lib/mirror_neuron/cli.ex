defmodule MirrorNeuron.CLI do
  require Logger

  alias MirrorNeuron.Config
  alias MirrorNeuron.CLI.Commands.Bundle
  alias MirrorNeuron.CLI.Commands.Cluster
  alias MirrorNeuron.CLI.Commands.Control
  alias MirrorNeuron.CLI.DependencyCheck
  alias MirrorNeuron.CLI.Commands.Inspect
  alias MirrorNeuron.CLI.Commands.Run
  alias MirrorNeuron.CLI.Commands.Server
  alias MirrorNeuron.CLI.Commands.Validate
  alias MirrorNeuron.CLI.Output
  alias MirrorNeuron.MonitorCLI

  def main(args) do
    {verbose, args_without_v} = extract_verbose(args)
    prepared_args = prepare_environment(args_without_v)
    maybe_configure_ephemeral_api_port(prepared_args)
    maybe_start_distribution()
    configure_logger(prepared_args, verbose)

    with :ok <- maybe_verify_dependencies(prepared_args),
         {:ok, _apps} <- Application.ensure_all_started(:mirror_neuron) do
      dispatch(prepared_args)
    else
      {:error, reason} ->
        Output.abort(reason)
    end
  end

  defp extract_verbose(args) do
    if Enum.any?(args, &(&1 in ["-v", "--verbose"])) do
      {true, Enum.reject(args, &(&1 in ["-v", "--verbose"]))}
    else
      {false, args}
    end
  end

  defp prepare_environment(["monitor" | rest]),
    do: ["monitor" | MonitorCLI.prepare_environment(rest)]

  defp prepare_environment(["cluster" | rest]),
    do: ["cluster" | Cluster.prepare_environment(rest)]

  defp prepare_environment(args) do
    maybe_prepare_local_control(args)
    args
  end

  defp maybe_configure_ephemeral_api_port(args) do
    if DependencyCheck.service_command?(args) do
      System.put_env("MIRROR_NEURON_API_ENABLED", "true")
      :ok
    else
      System.put_env("MIRROR_NEURON_API_ENABLED", "false")
    end
  end

  defp maybe_prepare_local_control([command | _rest])
       when command in ["pause", "resume", "cancel", "send"] do
    prepare_local_control_env()
  end

  defp maybe_prepare_local_control(["job", command | _rest])
       when command in ["pause", "resume", "cancel", "send"] do
    prepare_local_control_env()
  end

  defp maybe_prepare_local_control(_args), do: :ok

  defp prepare_local_control_env do
    if is_nil(System.get_env("MIRROR_NEURON_NODE_NAME")) do
      System.cmd("epmd", ["-daemon"])
      host = hostname_short()

      System.put_env(
        "MIRROR_NEURON_NODE_NAME",
        "cli-control-#{System.system_time(:second)}-#{System.unique_integer([:positive])}@#{host}"
      )
    end

    System.put_env("MIRROR_NEURON_NODE_ROLE", "control")
    System.put_env("MIRROR_NEURON_COOKIE", Config.string("MIRROR_NEURON_COOKIE", :cookie))
  end

  defp maybe_verify_dependencies(args) do
    if DependencyCheck.service_command?(args) do
      DependencyCheck.verify_service_dependencies()
    else
      :ok
    end
  end

  defp dispatch(["standalone-start"]), do: Server.run()
  defp dispatch(["server"]), do: Server.run()
  defp dispatch(["cluster" | rest]), do: Cluster.run(rest)
  defp dispatch(["job", "list" | rest]), do: Inspect.jobs(rest)
  defp dispatch(["job", "inspect", job_id]), do: Inspect.job(job_id)
  defp dispatch(["job", "agents", job_id]), do: Inspect.agents(job_id)
  defp dispatch(["job", "events", job_id]), do: Inspect.events(job_id)
  defp dispatch(["job", "pause", job_id]), do: Control.pause(job_id)
  defp dispatch(["job", "resume", job_id]), do: Control.resume(job_id)
  defp dispatch(["job", "cancel"]), do: Control.interactive_cancel()
  defp dispatch(["job", "cancel", job_id]), do: Control.cancel(job_id)
  defp dispatch(["job", "cleanup" | rest]), do: Control.cleanup_jobs(rest)

  defp dispatch(["job", "send", job_id, agent_id, message_json]),
    do: Control.send_message(job_id, agent_id, message_json)

  defp dispatch(["node", "list"]), do: Inspect.nodes()
  defp dispatch(["validate", job_path]), do: Validate.run(job_path)
  defp dispatch(["run", job_path | rest]), do: Run.run(job_path, Run.parse_options(rest))
  defp dispatch(["monitor" | rest]), do: MonitorCLI.main(rest)
  defp dispatch(["inspect", "job", job_id]), do: Inspect.job(job_id)
  defp dispatch(["inspect", "agents", job_id]), do: Inspect.agents(job_id)
  defp dispatch(["inspect", "nodes"]), do: Inspect.nodes()
  defp dispatch(["agent", "list", job_id]), do: Inspect.agents(job_id)
  defp dispatch(["events", job_id]), do: Inspect.events(job_id)
  defp dispatch(["bundle" | rest]), do: Bundle.run(rest)
  defp dispatch(["node", "add", node_name]), do: Control.add_node(node_name)
  defp dispatch(["node", "remove", node_name]), do: Control.remove_node(node_name)
  defp dispatch(["pause", job_id]), do: Control.pause(job_id)
  defp dispatch(["resume", job_id]), do: Control.resume(job_id)
  defp dispatch(["cancel"]), do: Control.interactive_cancel()
  defp dispatch(["cancel", job_id]), do: Control.cancel(job_id)

  defp dispatch(["send", job_id, agent_id, message_json]),
    do: Control.send_message(job_id, agent_id, message_json)

  defp dispatch(_args), do: Output.usage()

  defp configure_logger(_args, false), do: set_log_level(:error)

  # Show warnings when explicitly requested.
  defp configure_logger(_args, true), do: set_log_level(:warning)

  defp set_log_level(level) do
    :logger.set_primary_config(:level, level)
    :logger.set_handler_config(:default, :level, level)

    if MirrorNeuron.CLI.UI.interactive?() do
      :logger.update_handler_config(:default, :config, %{type: {:device, Owl.LiveScreen}})
    end

    Logger.configure(level: level)
  end

  defp maybe_start_distribution do
    node_name = System.get_env("MIRROR_NEURON_NODE_NAME")
    cookie = System.get_env("MIRROR_NEURON_COOKIE")

    cond do
      Node.alive?() ->
        :ok

      is_nil(node_name) or node_name == "" ->
        :ok

      true ->
        start_distributed_node!(node_name)

        if cookie && cookie != "" do
          Node.set_cookie(String.to_atom(cookie))
        end

        connect_configured_cluster_nodes(node_name)
        :ok
    end
  end

  defp start_distributed_node!(node_name) do
    mode = node_name_mode(node_name)
    normalized_name = normalize_node_name_for_mode(node_name, mode)

    case Node.start(String.to_atom(normalized_name), mode) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        raise "failed to start distributed node #{normalized_name} (#{mode}): #{inspect(reason)}"
    end
  end

  defp node_name_mode(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [_name, host] ->
        if String.contains?(host, "."), do: :longnames, else: :shortnames

      _ ->
        :shortnames
    end
  end

  defp normalize_node_name_for_mode(node_name, :longnames), do: node_name
  defp normalize_node_name_for_mode(node_name, :shortnames), do: short_node_name(node_name)

  defp short_node_name(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [name, host] ->
        short_host =
          host
          |> String.split(".", parts: 2)
          |> List.first()

        "#{name}@#{short_host}"

      _ ->
        node_name
    end
  end

  defp connect_configured_cluster_nodes(self_node_name) do
    "MIRROR_NEURON_CLUSTER_NODES"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.reject(&same_node_name?(&1, self_node_name))
    |> Enum.each(fn peer ->
      if connect_peer(peer) do
        Logger.notice("Successfully connected to cluster peer: #{peer}")
      else
        Logger.warning("Failed to connect to cluster peer: #{peer}")
      end
    end)
  end

  defp connect_peer(peer) do
    full_peer = String.to_atom(peer)
    short_peer = peer |> short_node_name() |> String.to_atom()

    if shortnames_node?() do
      Node.connect(short_peer)
    else
      Node.connect(full_peer) or (short_peer != full_peer and Node.connect(short_peer))
    end
  end

  defp same_node_name?(left, right) do
    left == right or short_node_name(left) == short_node_name(right)
  end

  defp shortnames_node? do
    Node.self()
    |> Atom.to_string()
    |> short_node_name()
    |> then(&(Atom.to_string(Node.self()) == &1))
  end

  defp hostname_short do
    [host | _rest] = String.split(System.cmd("hostname", []) |> elem(0) |> String.trim(), ".")
    host
  end
end
