defmodule MirrorNeuron.Runtime.RunnerResources do
  @moduledoc false

  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Runner.DockerCompose
  alias MirrorNeuron.SafeAccess
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
  def cleanup_native_resources(job_id) when is_binary(job_id) and job_id != "" do
    with {:ok, _result} <- cleanup_native_resources_with_result(job_id) do
      :ok
    end
  end

  @doc false
  def cleanup_native_resources_with_result(job_id)
      when is_binary(job_id) and job_id != "" do
    with {:ok, result} <-
           ModelServices.native_resource_command(%{
             "operation" => "cleanup",
             # This boundary is used for both stable definitions and physical
             # runs. Registry selectors are additive, so matching the runtime
             # identity against both fields cleans the exact owned records in
             # either lifecycle without broadening cleanup to other jobs.
             "job_id" => job_id,
             "run_id" => job_id
           }),
         :ok <- ensure_no_cleanup_errors(result, "native resource") do
      {:ok, result}
    end
  end

  def cleanup_native_resources(_job_id), do: {:error, :invalid_job_id}

  def cleanup_native_resources_with_result(_job_id), do: {:error, :invalid_job_id}

  @doc false
  def cleanup_native_resource_external_ids(kind, external_ids)
      when is_binary(kind) and is_list(external_ids) do
    with {:ok, result} <-
           ModelServices.native_resource_command(%{
             "operation" => "cleanup",
             "external_ids" => Enum.filter(external_ids, &is_binary/1),
             "resource_kinds" => [kind]
           }),
         :ok <- ensure_no_cleanup_errors(result, "native resource") do
      :ok
    end
  end

  def cleanup_native_resource_external_ids(_kind, _external_ids),
    do: {:error, :invalid_native_resource_selector}

  @doc false
  def cleanup_retired_native_resources(retired, current)
      when is_map(retired) and is_map(current) do
    current_keys =
      current
      |> native_resource_descriptors()
      |> MapSet.new(fn descriptor ->
        {detail(descriptor, "kind"), detail(descriptor, "external_id")}
      end)

    failures =
      retired
      |> native_resource_descriptors()
      |> Enum.reject(fn descriptor ->
        MapSet.member?(current_keys, {
          detail(descriptor, "kind"),
          detail(descriptor, "external_id")
        })
      end)
      |> Enum.group_by(fn descriptor ->
        {detail(descriptor, "owner_node"), detail(descriptor, "kind")}
      end)
      |> Enum.flat_map(fn {{owner_node, kind}, descriptors} ->
        external_ids =
          descriptors
          |> Enum.map(&detail(&1, "external_id"))
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()

        with {:ok, node} <- native_resource_node(owner_node),
             :ok <-
               NodeAdapter.rpc_call(
                 node,
                 __MODULE__,
                 :cleanup_native_resource_external_ids,
                 [kind, external_ids],
                 120_000
               ) do
          []
        else
          reason ->
            [
              %{
                node: to_string(owner_node || NodeAdapter.self()),
                kind: kind,
                external_ids: external_ids,
                reason: reason
              }
            ]
        end
      end)

    if failures == [], do: :ok, else: {:error, failures}
  end

  def cleanup_retired_native_resources(_retired, _current), do: :ok

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

  defp native_resource_descriptors(job) do
    metadata =
      detail(job, "metadata") ||
        job |> detail("manifest") |> detail("metadata") || %{}

    native = detail(metadata, "mn_native_resources")

    case detail(native, "resources") do
      resources when is_list(resources) ->
        Enum.filter(resources, fn descriptor ->
          is_map(descriptor) and
            detail(descriptor, "kind") in ["docker_worker", "docker_compose", "openshell"] and
            is_binary(detail(descriptor, "external_id")) and
            detail(descriptor, "external_id") != ""
        end)

      _other ->
        []
    end
  end

  defp native_resource_node(nil), do: {:ok, NodeAdapter.self()}
  defp native_resource_node(""), do: {:ok, NodeAdapter.self()}
  defp native_resource_node(node) when is_atom(node), do: {:ok, node}
  defp native_resource_node(node) when is_binary(node), do: SafeAccess.node_name_to_atom(node)
  defp native_resource_node(_node), do: {:error, :invalid_owner_node}

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
  defp key_atom("mn_native_resources"), do: :mn_native_resources
  defp key_atom("resources"), do: :resources
  defp key_atom("kind"), do: :kind
  defp key_atom("external_id"), do: :external_id
  defp key_atom("owner_node"), do: :owner_node
  defp key_atom("project_name"), do: :project_name
  defp key_atom("runner_module"), do: :runner_module
  defp key_atom("runtime_driver"), do: :runtime_driver
  defp key_atom("docker_worker_container_name"), do: :docker_worker_container_name
  defp key_atom("docker_worker_compose_service"), do: :docker_worker_compose_service
  defp key_atom(_key), do: nil
end
