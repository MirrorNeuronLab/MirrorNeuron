defmodule MirrorNeuron.Runner.DockerCompose do
  @moduledoc false

  alias MirrorNeuron.ModelServices

  alias Mirrorneuron.Cluster.V1.{
    CleanupDockerComposeRequest,
    DockerComposeStatusRequest,
    PrepareDockerComposeRequest
  }

  @poll_ms 5_000

  # Docker Compose is created by the selected node's native SDK service, never
  # by Core's own runtime compose. The runner owns only its one project record
  # and keeps the service attempt alive while that project is healthy.
  def run(payload, config, opts \\ [])

  def run(_payload, config, opts) when is_map(config) do
    with {:ok, project} <- prepare_project(config, opts),
         :ok <- emit(opts, "docker_compose_ready", %{"project_name" => project["project_name"]}) do
      try do
        await_project(project, opts)
      after
        _ = cleanup_project(project)
      end
    end
  end

  def run(_payload, _config, _opts), do: {:error, "DockerCompose config must be an object"}

  defp prepare_project(config, opts) do
    with {:ok, record} <- project_record(config) do
      request = %PrepareDockerComposeRequest{
        manifest_json:
          Jason.encode!(%{
            "nodes" => [
              %{
                "node_id" => Keyword.get(opts, :agent_id, "docker-compose"),
                "config" => config
              }
            ]
          }),
        submission_id: record["project_name"],
        version: 1
      }

      with {:ok, response} <- ModelServices.prepare_docker_compose(request),
           {:ok, result} <- decode(response.result_json, "prepare"),
           [project | _] <- result["projects"] do
        {:ok, project}
      else
        [] -> {:error, "DockerCompose prepare returned no project"}
        {:error, _reason} = error -> error
        other -> {:error, "DockerCompose prepare returned invalid response: #{inspect(other)}"}
      end
    end
  end

  defp await_project(project, opts) do
    case project_status(project) do
      {:ok, %{"ready" => true}} ->
        emit(opts, "docker_compose_health", %{
          "project_name" => project["project_name"],
          "status" => "healthy"
        })

        Process.sleep(@poll_ms)
        await_project(project, opts)

      {:ok, status} ->
        emit(opts, "docker_compose_health", %{
          "project_name" => project["project_name"],
          "status" => "failed",
          "details" => status
        })

        {:error, "DockerCompose project is not healthy"}

      {:error, reason} ->
        emit(opts, "docker_compose_health", %{
          "project_name" => project["project_name"],
          "status" => "failed",
          "details" => to_string(reason)
        })

        {:error, reason}
    end
  end

  defp project_status(project) do
    request = %DockerComposeStatusRequest{project_json: Jason.encode!(project), version: 1}

    with {:ok, response} <- ModelServices.docker_compose_status(request),
         {:ok, result} <- decode(response.result_json, "status") do
      {:ok, result}
    end
  end

  defp cleanup_project(project) do
    request = %CleanupDockerComposeRequest{projects_json: [Jason.encode!(project)], version: 1}
    ModelServices.cleanup_docker_compose(request)
  rescue
    _ -> :ok
  end

  defp project_record(config) do
    case Map.get(config, "mn_docker_compose") do
      %{"project_name" => project_name} = record
      when is_binary(project_name) and project_name != "" ->
        {:ok, record}

      _ ->
        {:error, "DockerCompose runner requires a native prepared project record"}
    end
  end

  defp decode(value, stage) do
    case Jason.decode(value) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:ok, _other} ->
        {:error, "DockerCompose #{stage} response is not an object"}

      {:error, reason} ->
        {:error, "DockerCompose #{stage} response is invalid JSON: #{Exception.message(reason)}"}
    end
  end

  defp emit(opts, event_type, payload) do
    case Keyword.get(opts, :event_callback) do
      callback when is_function(callback, 2) ->
        callback.(event_type, Map.put(payload, "runner", "docker_compose"))

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
