defmodule MirrorNeuron.Runner.DockerWorker do
  @behaviour MirrorNeuron.Runner
  @moduledoc "Docker worker invocation lifecycle and prepared-resource adapter contract."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Runner.DockerWorker.Context
  alias MirrorNeuron.Runner.DockerCommand
  alias MirrorNeuron.Runner.DockerWorker.Output
  alias MirrorNeuron.Runner.DockerWorker.Preparation
  alias MirrorNeuron.Runner.DockerWorker.Settings
  alias MirrorNeuron.Runner.DockerWorker.Uploads
  alias MirrorNeuron.Runner.DockerWorker.Workspace

  @impl true
  def stop_commands(job_id, agents), do: DockerCommand.terminate_agents(job_id, agents)

  @impl true
  def prepared_key(config, :finish),
    do: MirrorNeuron.Sandbox.DockerJobSandbox.configured_container_name(config)

  def prepared_key(_config, _transition), do: nil

  @impl true
  defdelegate stop_prepared(config),
    to: MirrorNeuron.Sandbox.DockerJobSandbox,
    as: :stop_prepared_container

  @impl true
  def run(payload, config, opts \\ []) do
    DockerCommand.run(opts, &run_owned(payload, config, &1))
  end

  defp run_owned(payload, config, opts) do
    runner_name = Settings.build_runner_name(config, opts)

    base_dir =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_docker_worker_#{runner_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = Context.build_message(payload, config, opts)

    try do
      with :ok <- Preparation.reject_published_ports(config),
           :ok <- Uploads.copy_uploads(base_dir, config, opts),
           :ok <- Uploads.copy_build_context_uploads(base_dir, config, opts),
           :ok <- Context.write_runtime_files(base_dir, message, opts),
           {:ok, image} <- Preparation.resolve_image(config, base_dir, opts),
           :ok <- Preparation.ensure_docker_model_runner_model(config, opts),
           {:ok, output, exit_code, command_name} <-
             Workspace.run_worker_command(image, base_dir, config, opts) do
        result =
          Output.sanitize_result(%{
            "sandbox_name" => runner_name,
            "container_name" => command_name,
            "exit_code" => exit_code,
            "runner_exit_code" => exit_code,
            "stdout" => output,
            "stderr" => "",
            "logs" => String.trim(output),
            "raw_output" => output,
            "runner" => "docker_worker",
            "image" => image,
            "node_name" => to_string(Node.self())
          })

        if exit_code == 0, do: {:ok, result}, else: {:error, result}
      end
    after
      File.rm_rf(base_dir)
    end
  end
end
