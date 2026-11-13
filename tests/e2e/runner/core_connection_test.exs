defmodule MirrorNeuron.Runner.CoreConnectionTest do
  use ExUnit.Case, async: false

  test "Docker invocation binds the owner's Core credentials even without model or context settings" do
    keys = ~w(MN_GRPC_AUTH_TOKEN MN_RUNTIME_MODEL_CONTROL_TARGET)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    System.put_env("MN_GRPC_AUTH_TOKEN", "execution-fixture")
    System.put_env("MN_RUNTIME_MODEL_CONTROL_TARGET", "execution-core:55351")

    if is_nil(Process.whereis(MirrorNeuron.Runner.DockerProcessRegistry)) do
      start_supervised!(
        {Registry, keys: :duplicate, name: MirrorNeuron.Runner.DockerProcessRegistry}
      )
    end

    directory =
      Path.join(System.tmp_dir!(), "mn-core-binding-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    fake = Path.join(directory, "docker")
    args = Path.join(directory, "invocation")

    File.write!(fake, """
    #!/bin/sh
    if [ "$1" = inspect ]; then echo running; exit 0; fi
    if [ "$1" = exec ] && [ "$2" = -w ]; then
      printf '%s\n' "$@" > '#{args}'
      echo completed
    fi
    exit 0
    """)

    File.chmod!(fake, 0o700)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf(directory)
    end)

    assert {:ok, result} =
             MirrorNeuron.Runner.DockerWorker.run(
               %{},
               %{
                 "image" => "fixture:local",
                 "docker_bin" => fake,
                 "docker_worker_container_name" => "prepared-fixture",
                 "command" => ["true"],
                 "environment" => %{
                   "MN_GRPC_AUTH_TOKEN" => "surface-fixture",
                   "MN_GRPC_TARGET" => "127.0.0.1:1"
                 }
               },
               job_id: "core-binding",
               agent_id: "reviewer"
             )

    assert result["stdout"] =~ "completed"
    invocation = File.read!(args)
    assert invocation =~ "MN_GRPC_TARGET=execution-core:55351"
    assert invocation =~ "MN_GRPC_AUTH_TOKEN=execution-fixture"
    refute invocation =~ "surface-fixture"
    refute result["stdout"] =~ "execution-fixture"
  end
end
