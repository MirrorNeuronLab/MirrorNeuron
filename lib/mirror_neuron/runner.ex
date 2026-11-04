defmodule MirrorNeuron.Runner do
  @moduledoc """
  Execution and control boundary for runner adapters. The coordinator owns
  the Run, admission fence and durable lifecycle. An adapter translates an
  invocation or cleanup request to operations on its own resources.
  """
  alias MirrorNeuron.Runner.{DockerCompose, DockerWorker, HostLocal, OpenShell}
  alias MirrorNeuron.Runtime.NodeAdmission
  alias MirrorNeuron.SafeAccess

  @adapters [
    {HostLocal, "host_local"},
    {DockerWorker, "docker_worker"},
    {OpenShell, "openshell"},
    {DockerCompose, "docker_compose"}
  ]

  @type transition :: :pause | :finish | :retire
  @callback run(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_commands(String.t(), :all | [String.t()]) :: :ok | {:error, term()}
  @callback prepared_key(map(), transition()) :: term() | nil
  @callback stop_prepared(map()) :: :ok | {:error, term()}
  @callback resumable_after_stop?(map()) :: boolean()
  @optional_callbacks prepared_key: 2, stop_prepared: 1, resumable_after_stop?: 1

  def adapters, do: Enum.map(@adapters, &elem(&1, 0))

  def driver(config) do
    case SafeAccess.map_get(config, "runner_module") do
      name when is_binary(name) or is_atom(name) ->
        name = String.trim_leading(to_string(name), "Elixir.")

        Enum.find_value(@adapters, fn {adapter, driver} ->
          if String.ends_with?(name, "." <> List.last(Module.split(adapter))), do: driver
        end)

      _ ->
        nil
    end
  end

  def run(payload, config, opts) do
    with {:ok, adapter} <- resolve(SafeAccess.map_get(config, "runner_module")) do
      NodeAdmission.run(config, Keyword.fetch!(opts, :job_id), fn ->
        adapter.run(payload, config, opts)
      end)
    end
  end

  def stop_commands(job_id, agents) do
    errors =
      for adapter <- adapters(),
          {:error, reason} <- [adapter.stop_commands(job_id, agents)],
          do: {adapter, reason}

    if errors == [], do: :ok, else: {:error, errors}
  end

  # Persisted older definitions may carry only the prepared resource record.
  # An explicit runner always wins over unrelated fields on its config.
  def stop_prepared(configs, transition) do
    configs
    |> Enum.flat_map(fn config ->
      adapter = prepared_adapter(config)

      if adapter && Code.ensure_loaded?(adapter) && function_exported?(adapter, :prepared_key, 2) do
        case adapter.prepared_key(config, transition) do
          nil -> []
          key -> [{adapter, key, config}]
        end
      else
        []
      end
    end)
    |> Enum.uniq_by(fn {adapter, key, _config} -> {adapter, key} end)
    |> Enum.reduce([], fn {adapter, _key, config}, errors ->
      case adapter.stop_prepared(config) do
        :ok -> errors
        {:error, reason} -> [{adapter, reason} | errors]
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def docker_worker?(config) do
    case SafeAccess.map_get(config, "runner_module") do
      nil -> prepared_adapter(config) == DockerWorker
      _ -> driver(config) == "docker_worker"
    end
  end

  def resumable_after_stop?(config) do
    adapter = prepared_adapter(config)

    not is_nil(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :resumable_after_stop?, 1) and
      function_exported?(adapter, :stop_prepared, 1) and
      function_exported?(adapter, :prepared_key, 2) and
      not is_nil(adapter.prepared_key(config, :pause)) and adapter.resumable_after_stop?(config)
  end

  defp prepared_adapter(config) do
    case SafeAccess.map_get(config, "runner_module") do
      nil ->
        cond do
          is_map(SafeAccess.map_get(config, "mn_docker_compose")) ->
            DockerCompose

          (SafeAccess.map_get(config, "runtime_driver") == "docker_worker" or
             SafeAccess.map_get(config, "docker_worker_container_name")) ||
              SafeAccess.map_get(config, "docker_worker_compose_service") ->
            DockerWorker

          true ->
            nil
        end

      name ->
        case resolve(name) do
          {:ok, adapter} -> adapter
          _ -> nil
        end
    end
  end

  defp resolve(nil), do: {:ok, OpenShell}

  # Stored Python bundles from before the runner namespace migration.
  defp resolve("MirrorNeuron.Sandbox.OpenShell"), do: {:ok, OpenShell}
  defp resolve("Elixir." <> name), do: resolve(name)

  defp resolve(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run, 3),
      do: {:ok, module},
      else: {:error, "Unknown runner module"}
  end

  defp resolve(name) when is_binary(name) do
    [name] |> Module.safe_concat() |> resolve()
  rescue
    ArgumentError -> {:error, "Unknown runner module"}
  end

  defp resolve(_), do: {:error, "Invalid runner module"}
end
