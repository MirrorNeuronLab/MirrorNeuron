defmodule MirrorNeuron.NativeResourceBoundaryTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.{DockerWorker, HostLocal}
  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}

  setup do
    keys = [
      "MN_CORE_ALLOW_NATIVE_RESOURCE_PREP",
      "MN_CORE_ALLOW_NATIVE_SANDBOX_PREP",
      "MN_DOCKER_WORKER_CONTAINER_NAME",
      "MN_OPENSHELL_SANDBOX_NAME",
      "MN_OPENSHELL_SSH_HOST"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})

    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "DockerWorker sandbox requires a prepared container by default" do
    assert {:error, reason} = DockerJobSandbox.ensure("job-boundary", "worker:latest", %{})
    assert reason =~ "docker_worker sandbox"
    assert reason =~ "mn-python-sdk/API/CLI"
  end

  test "DockerWorker sandbox consumes an SDK-prepared container name" do
    assert {:ok, sandbox} =
             DockerJobSandbox.ensure("job-boundary", "worker:latest", %{
               "docker_worker_container_name" => "mn-prepared-worker"
             })

    assert sandbox["container_name"] == "mn-prepared-worker"
    assert sandbox["image"] == "worker:latest"
  end

  test "OpenShell sandbox requires a prepared sandbox by default" do
    assert {:error, reason} = OpenShellJobSandbox.ensure("job-boundary", %{})
    assert reason =~ "OpenShell sandbox"
    assert reason =~ "mn-python-sdk/API/CLI"
  end

  test "OpenShell sandbox consumes an SDK-prepared sandbox name" do
    assert {:ok, sandbox} =
             OpenShellJobSandbox.ensure("job-boundary", %{
               "sandbox_name" => "prepared-sandbox",
               "ssh_host" => "prepared-host"
             })

    assert sandbox["sandbox_name"] == "prepared-sandbox"
    assert sandbox["ssh_host"] == "prepared-host"
  end

  test "HostLocal refuses to create Python environments in Core by default" do
    assert {:error, reason} =
             HostLocal.run(
               %{},
               %{
                 "command" => ["python", "-c", "print('unused')"],
                 "python_environment" => %{"packages" => ["requests"]}
               },
               job_id: "job-boundary",
               agent_id: "host"
             )

    assert reason =~ "python_environment preparation is owned by mn-python-sdk"
  end

  test "DockerWorker refuses image builds in Core by default" do
    assert {:error, reason} =
             DockerWorker.run(
               %{},
               %{
                 "docker_worker_image" => "bundle/docker_worker",
                 "command" => ["sh", "-lc", "true"]
               },
               job_id: "job-boundary",
               agent_id: "docker"
             )

    assert reason =~ "docker_worker image build is owned by mn-python-sdk"
  end
end
