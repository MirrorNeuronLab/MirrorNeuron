defmodule MirrorNeuron.Execution.Profile do
  @moduledoc false

  alias MirrorNeuron.Cluster.NodeState

  @active_statuses ["healthy", "joining"]
  @profile_keys ["execution_profile", "profile"]
  @openshell_keys [
    "from",
    "image",
    "custom_openshell_image",
    "pool",
    "pool_slots",
    "slots",
    "gpu",
    "policy",
    "providers",
    "remote",
    "ssh_key",
    "no_auto_providers",
    "reuse_shared_sandbox",
    "persistent_workspace",
    "cleanup_remote_dir",
    "sandbox_upload_path",
    "shared_workspace_safe",
    "warmup_command",
    "warmup_timeout_ms",
    "max_concurrency",
    "video_codecs",
    "required_capabilities"
  ]

  def apply_to_config(config) when is_map(config) do
    case profile_name(config) do
      nil ->
        stringify_map(config)

      name ->
        case fetch(name) do
          {:ok, profile} ->
            profile
            |> config_from_profile()
            |> Map.merge(stringify_map(config))
            |> Map.put("execution_profile", name)

          {:error, _reason} ->
            config
            |> stringify_map()
            |> Map.put("execution_profile", name)
        end
    end
  end

  def apply_to_config(_config), do: %{}

  def profile_name(config) when is_map(config) do
    Enum.find_value(@profile_keys, fn key ->
      case Map.get(config, key) || Map.get(config, String.to_atom(key)) do
        name when is_binary(name) and name != "" -> name
        nil -> nil
        name when is_atom(name) -> Atom.to_string(name)
        _ -> nil
      end
    end)
  end

  def profile_name(_config), do: nil

  def fetch(name) when is_binary(name) do
    profiles = profiles()

    case Map.fetch(profiles, name) do
      {:ok, profile} -> {:ok, Map.put(profile, "name", name)}
      :error -> {:error, "execution profile #{inspect(name)} is not configured"}
    end
  end

  def profiles do
    :mirror_neuron
    |> Application.get_env(:execution_profiles, %{})
    |> normalize_profiles()
  end

  def node_advertisement do
    warmups = warm_profile_statuses()
    healthy_profiles = healthy_profile_names(warmups)

    %{
      "profiles" => healthy_profiles,
      "profile_health" => warmups,
      "capabilities" => node_capabilities(healthy_profiles),
      "gpu" => node_gpu?()
    }
  end

  def eligible_nodes(nil),
    do: [Node.self() | Node.list()] |> Enum.uniq() |> Enum.map(&to_string/1)

  def eligible_nodes(profile_name) do
    NodeState.list()
    |> Enum.filter(&eligible_node?(profile_name, &1))
    |> Enum.map(&Map.get(&1, "node"))
    |> Enum.reject(&is_nil/1)
  end

  def eligible_node?(nil, _node_state), do: true

  def eligible_node?(profile_name, node_state) when is_map(node_state) do
    with {:ok, profile} <- fetch(profile_name),
         true <- Map.get(node_state, "status", "offline") in @active_statuses,
         true <- profile_name in list_value(node_state["profiles"]),
         true <- gpu_requirement_met?(profile, node_state),
         true <- capabilities_met?(profile, node_state) do
      true
    else
      _ -> false
    end
  end

  def eligible_node?(_profile_name, _node_state), do: false

  def member_eligible?(nil, _member), do: true

  def member_eligible?(profile_name, %{name: node}) do
    node_name = member_node_name(node)

    case NodeState.fetch(node_name) do
      {:ok, node_state} ->
        eligible_node?(profile_name, node_state)

      {:error, _reason} ->
        false
    end
  end

  defp member_node_name({_supervisor, node}), do: to_string(node)
  defp member_node_name(node), do: to_string(node)

  def warm_profile_statuses do
    configured = profiles()
    advertised = advertised_profile_names(configured)

    configured
    |> Map.take(advertised)
    |> Enum.into(%{}, fn {name, profile} ->
      {name, warm_profile(profile)}
    end)
  end

  defp config_from_profile(profile) do
    openshell =
      profile
      |> Map.take(@openshell_keys)
      |> normalize_openshell_aliases()

    profile
    |> Map.get("openshell", %{})
    |> stringify_map()
    |> normalize_openshell_aliases()
    |> Map.merge(openshell)
  end

  defp normalize_openshell_aliases(config) do
    config
    |> maybe_promote("image", "from")
    |> maybe_promote("slots", "pool_slots")
  end

  defp maybe_promote(config, from_key, to_key) do
    cond do
      Map.get(config, to_key) not in [nil, ""] ->
        Map.delete(config, from_key)

      Map.get(config, from_key) not in [nil, ""] ->
        config
        |> Map.put(to_key, Map.get(config, from_key))
        |> Map.delete(from_key)

      true ->
        Map.delete(config, from_key)
    end
  end

  defp warm_profile(profile) do
    case Map.get(profile, "warmup_command") || get_in(profile, ["openshell", "warmup_command"]) do
      command when is_binary(command) and command != "" ->
        case System.cmd("sh", ["-lc", command], stderr_to_stdout: true) do
          {_output, 0} ->
            %{"status" => "healthy"}

          {output, exit_code} ->
            %{
              "status" => "unhealthy",
              "reason" => "warmup failed with exit #{exit_code}",
              "logs" => String.slice(output, 0, 2_000)
            }
        end

      _ ->
        %{"status" => "healthy"}
    end
  rescue
    error ->
      %{"status" => "unhealthy", "reason" => Exception.message(error)}
  end

  defp healthy_profile_names(statuses) do
    statuses
    |> Enum.filter(fn {_name, status} -> Map.get(status, "status") == "healthy" end)
    |> Enum.map(fn {name, _status} -> name end)
    |> Enum.sort()
  end

  defp advertised_profile_names(configured) do
    case System.get_env("MN_NODE_EXECUTION_PROFILES", "") |> split_csv() do
      [] -> []
      names -> Enum.filter(names, &Map.has_key?(configured, &1))
    end
  end

  defp node_capabilities(profile_names) do
    base = split_csv(System.get_env("MN_NODE_CAPABILITIES", ""))

    profile_capabilities =
      profile_names
      |> Enum.flat_map(fn name ->
        case fetch(name) do
          {:ok, profile} -> list_value(Map.get(profile, "capabilities"))
          {:error, _reason} -> []
        end
      end)

    Enum.uniq(base ++ profile_capabilities)
  end

  defp node_gpu? do
    case System.get_env("MN_NODE_GPU") do
      value when value in ["1", "true", "TRUE", "True", "yes", "on"] -> true
      value when value in ["0", "false", "FALSE", "False", "no", "off"] -> false
      _ -> hardware_gpu?()
    end
  end

  defp hardware_gpu? do
    gpu = MirrorNeuron.Cluster.Hardware.info() |> Map.get(:gpu)
    gpu not in [nil, [], "", "Unknown", "Unknown or None", "Unsupported", "Not available"]
  rescue
    _ -> false
  end

  defp gpu_requirement_met?(profile, node_state) do
    not truthy?(Map.get(profile, "gpu")) or truthy?(Map.get(node_state, "gpu"))
  end

  defp capabilities_met?(profile, node_state) do
    required = list_value(Map.get(profile, "required_capabilities"))
    available = MapSet.new(list_value(Map.get(node_state, "capabilities")))
    Enum.all?(required, &MapSet.member?(available, &1))
  end

  defp normalize_profiles(profiles) when is_map(profiles) do
    Enum.into(profiles, %{}, fn {name, profile} ->
      {to_string(name), stringify_map(profile)}
    end)
  end

  defp normalize_profiles(_profiles), do: %{}

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp list_value(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list_value(value) when is_binary(value), do: split_csv(value)
  defp list_value(_value), do: []

  defp split_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_csv(_value), do: []

  defp truthy?(value) when value in [true, "true", "TRUE", "True", "1", 1, "yes", "on"],
    do: true

  defp truthy?(_value), do: false
end
