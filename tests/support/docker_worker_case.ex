defmodule MirrorNeuron.DockerWorkerCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.DockerWorkerCase
    end
  end

  alias MirrorNeuron.Sandbox.DockerJobSandbox

  setup do
    previous_skills_root = System.get_env("MN_SKILLS_ROOT")
    previous_workspace_root = System.get_env("MN_WORKSPACE_ROOT")
    previous_buildkit = System.get_env("DOCKER_BUILDKIT")
    previous_worker_buildkit = System.get_env("MN_DOCKER_WORKER_BUILDKIT")
    previous_node_runtime_models = System.get_env("MN_NODE_RUNTIME_MODELS")
    previous_prepared_container = System.get_env("MN_DOCKER_WORKER_CONTAINER_NAME")
    prepared_container = "mn-test-prepared-#{System.unique_integer([:positive])}"

    System.put_env("MN_DOCKER_WORKER_CONTAINER_NAME", prepared_container)

    tmp_dir =
      Path.join(System.tmp_dir!(), "mn-docker-worker-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      if is_nil(previous_skills_root),
        do: System.delete_env("MN_SKILLS_ROOT"),
        else: System.put_env("MN_SKILLS_ROOT", previous_skills_root)

      if is_nil(previous_workspace_root),
        do: System.delete_env("MN_WORKSPACE_ROOT"),
        else: System.put_env("MN_WORKSPACE_ROOT", previous_workspace_root)

      if is_nil(previous_buildkit),
        do: System.delete_env("DOCKER_BUILDKIT"),
        else: System.put_env("DOCKER_BUILDKIT", previous_buildkit)

      if is_nil(previous_worker_buildkit),
        do: System.delete_env("MN_DOCKER_WORKER_BUILDKIT"),
        else: System.put_env("MN_DOCKER_WORKER_BUILDKIT", previous_worker_buildkit)

      if is_nil(previous_node_runtime_models),
        do: System.delete_env("MN_NODE_RUNTIME_MODELS"),
        else: System.put_env("MN_NODE_RUNTIME_MODELS", previous_node_runtime_models)

      if is_nil(previous_prepared_container),
        do: System.delete_env("MN_DOCKER_WORKER_CONTAINER_NAME"),
        else: System.put_env("MN_DOCKER_WORKER_CONTAINER_NAME", previous_prepared_container)

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, prepared_container: prepared_container}
  end

  def write_prepared_docker(path, script) do
    [shebang, body] = String.split(script, "\n", parts: 2)

    File.write!(path, """
    #{shebang}
    if [ "$1" = "inspect" ] && [ "$3" = "{{.State.Status}}" ]; then
      echo running
      exit 0
    fi
    #{body}
    """)
  end

  def cleanup_docker_job_on_exit(job_id, fake_docker) do
    on_exit(fn ->
      DockerJobSandbox.cleanup_job_local(job_id, %{"docker_bin" => fake_docker})
    end)
  end

  def docker_calls(path) do
    path
    |> File.read!()
    |> String.split("---\n", trim: true)
    |> Enum.map(fn call -> String.split(call, "\n", trim: true) end)
  end
end
