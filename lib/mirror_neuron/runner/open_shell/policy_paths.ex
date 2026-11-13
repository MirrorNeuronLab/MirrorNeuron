defmodule MirrorNeuron.Runner.OpenShell.PolicyPaths do
  @moduledoc "Resolves CLI inputs and prepares the existing minimal runtime filesystem policy."

  alias MirrorNeuron.Config

  def resolve_local_cli_paths(config, opts) do
    payloads_path =
      Keyword.get(opts, :payloads_path) ||
        Map.get(config, "__payloads_path") ||
        Map.get(config, :__payloads_path)

    config
    |> maybe_promote_custom_openshell_image()
    |> resolve_from_path(payloads_path)
    |> resolve_policy_path(payloads_path)
    |> resolve_local_cli_path("ssh_key", payloads_path)
  end

  defp maybe_promote_custom_openshell_image(config) do
    cond do
      Map.get(config, "from") not in [nil, ""] ->
        config

      is_binary(Map.get(config, "custom_openshell_image")) ->
        Map.put(config, "from", Map.get(config, "custom_openshell_image"))

      true ->
        config
    end
  end

  defp resolve_from_path(config, nil), do: config

  defp resolve_from_path(config, payloads_path) do
    case Map.get(config, "from") do
      nil ->
        config

      value when is_binary(value) ->
        resolved =
          if Path.type(value) == :absolute do
            value
          else
            Path.expand(value, payloads_path)
          end

        if File.exists?(resolved) do
          Map.put(config, "from", resolved)
        else
          config
        end

      _other ->
        config
    end
  end

  defp resolve_local_cli_path(config, _key, nil), do: config

  defp resolve_local_cli_path(config, key, payloads_path) do
    case Map.get(config, key) do
      nil ->
        config

      value when is_binary(value) ->
        resolved =
          if Path.type(value) == :absolute do
            value
          else
            Path.expand(value, payloads_path)
          end

        Map.put(config, key, resolved)

      _other ->
        config
    end
  end

  defp resolve_policy_path(config, nil), do: config

  defp resolve_policy_path(config, payloads_path) do
    config
    |> resolve_local_cli_path("policy", payloads_path)
    |> maybe_prepare_policy_runtime_filesystem()
  end

  defp maybe_prepare_policy_runtime_filesystem(%{"policy" => policy_path} = config)
       when is_binary(policy_path) do
    Map.put(config, "policy", prepare_policy_runtime_filesystem(policy_path))
  end

  defp maybe_prepare_policy_runtime_filesystem(config), do: config

  defp prepare_policy_runtime_filesystem(policy_path) do
    case File.read(policy_path) do
      {:ok, text} ->
        cond do
          String.contains?(text, "/dev/null") ->
            policy_path

          String.contains?(text, "filesystem_policy:") ->
            policy_path

          true ->
            write_runtime_policy(policy_path, append_runtime_filesystem_policy(text))
        end

      {:error, _reason} ->
        policy_path
    end
  end

  defp append_runtime_filesystem_policy(text) do
    String.trim_trailing(text) <> "\n\n" <> runtime_filesystem_policy()
  end

  defp runtime_filesystem_policy do
    """
    filesystem_policy:
      include_workdir: true
      read_only:
        - /usr
        - /lib
        - /etc
        - /var/log
        - /proc
        - /dev/urandom
      read_write:
        - /sandbox
        - /tmp
        - /dev/null
    """
  end

  defp write_runtime_policy(source_path, text) do
    digest =
      :crypto.hash(:sha256, source_path <> "\0" <> text)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    policy_dir =
      Path.join(Config.string("MN_TEMP_DIR", :temp_dir), "mirror_neuron_openshell_policies")

    File.mkdir_p!(policy_dir)
    target = Path.join(policy_dir, "#{digest}.yaml")
    File.write!(target, text)
    target
  end
end
