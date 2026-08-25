defmodule MirrorNeuron.Runtime.RunnerResources do
  @moduledoc false

  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Runner.DockerCompose
  alias Mirrorneuron.Cluster.V1.CleanupDockerWorkerRequest

  @node_paths [
    ["runtime_topology", "nodes"],
    ["topology", "nodes"],
    ["manifest", "flow", "nodes"],
    ["manifest", "agents", "nodes"],
    ["manifest", "nodes"]
  ]

  @doc false
  def cleanup_docker_worker(job_id) when is_binary(job_id) and job_id != "" do
    request = %CleanupDockerWorkerRequest{job_id: job_id, version: 1}

    with {:ok, response} <- ModelServices.cleanup_docker_worker(request),
         {:ok, result} <- decode_cleanup(response.result_json, "DockerWorker"),
         :ok <- ensure_no_cleanup_errors(result, "DockerWorker") do
      :ok
    end
  end

  def cleanup_docker_worker(_job_id), do: {:error, :invalid_job_id}

  @doc false
  def cleanup_prepared_compose_projects(job) when is_map(job) do
    job
    |> compose_configs()
    |> Enum.reduce_while(:ok, fn config, :ok ->
      case DockerCompose.cleanup_prepared_project(config) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def cleanup_prepared_compose_projects(_job), do: :ok

  @doc false
  def docker_worker?(job) when is_map(job) do
    has_docker_worker_metadata?(job) or
      Enum.any?(node_configs(job), &docker_worker_config?/1)
  end

  def docker_worker?(_job), do: false

  defp compose_configs(job) do
    job
    |> node_configs()
    |> Enum.filter(&(is_map(&1) and is_map(detail(&1, "mn_docker_compose"))))
    |> Enum.uniq_by(fn config ->
      config
      |> detail("mn_docker_compose")
      |> detail("project_name")
    end)
  end

  defp node_configs(job) do
    @node_paths
    |> Enum.flat_map(fn path ->
      case nested_detail(job, path) do
        nodes when is_list(nodes) -> Enum.map(nodes, &detail(&1, "config"))
        _ -> []
      end
    end)
    |> Enum.filter(&is_map/1)
  end

  defp has_docker_worker_metadata?(job) do
    job
    |> detail("manifest")
    |> detail("metadata")
    |> detail("mn_docker_workers")
    |> is_map()
  end

  defp docker_worker_config?(config) do
    runner_module = detail(config, "runner_module")

    (is_binary(runner_module) and String.ends_with?(runner_module, ".DockerWorker")) or
      detail(config, "runtime_driver") == "docker_worker" or
      is_binary(detail(config, "docker_worker_container_name")) or
      is_binary(detail(config, "docker_worker_compose_service"))
  end

  defp decode_cleanup(result_json, runner) when is_binary(result_json) do
    case Jason.decode(result_json) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:ok, _other} ->
        {:error, "#{runner} cleanup returned a non-object response"}

      {:error, reason} ->
        {:error, "#{runner} cleanup returned invalid JSON: #{Exception.message(reason)}"}
    end
  end

  defp decode_cleanup(_result_json, runner), do: {:error, "#{runner} cleanup returned no result"}

  defp ensure_no_cleanup_errors(result, runner) do
    case detail(result, "errors") do
      nil -> :ok
      [] -> :ok
      errors when is_list(errors) -> {:error, "#{runner} cleanup failed: #{inspect(errors)}"}
      _other -> {:error, "#{runner} cleanup returned invalid errors"}
    end
  end

  defp nested_detail(value, []), do: value

  defp nested_detail(value, [key | rest]) do
    value
    |> detail(key)
    |> nested_detail(rest)
  end

  defp detail(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, key_atom(key))
  defp detail(_other, _key), do: nil

  defp key_atom("runtime_topology"), do: :runtime_topology
  defp key_atom("topology"), do: :topology
  defp key_atom("manifest"), do: :manifest
  defp key_atom("flow"), do: :flow
  defp key_atom("agents"), do: :agents
  defp key_atom("nodes"), do: :nodes
  defp key_atom("config"), do: :config
  defp key_atom("metadata"), do: :metadata
  defp key_atom("mn_docker_workers"), do: :mn_docker_workers
  defp key_atom("mn_docker_compose"), do: :mn_docker_compose
  defp key_atom("project_name"), do: :project_name
  defp key_atom("runner_module"), do: :runner_module
  defp key_atom("runtime_driver"), do: :runtime_driver
  defp key_atom("docker_worker_container_name"), do: :docker_worker_container_name
  defp key_atom("docker_worker_compose_service"), do: :docker_worker_compose_service
  defp key_atom(_key), do: nil
end
