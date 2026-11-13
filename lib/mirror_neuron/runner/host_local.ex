defmodule MirrorNeuron.Runner.HostLocal do
  @behaviour MirrorNeuron.Runner
  @moduledoc "Host-local invocation lifecycle and runner adapter contract."

  alias MirrorNeuron.Runner.HostLocal.Command
  alias MirrorNeuron.Config
  alias MirrorNeuron.Runner.HostLocal.Context
  alias MirrorNeuron.Runner.HostLocal.Execution
  alias MirrorNeuron.Runner.HostLocal.Output
  alias MirrorNeuron.Runner.HostLocal.Ownership
  alias MirrorNeuron.Runner.HostLocal.PythonEnvironment
  alias MirrorNeuron.Runner.HostLocal.Uploads

  defdelegate terminate_job(job_id), to: Ownership
  defdelegate terminate_agents(job_id, agent_ids), to: Ownership
  defdelegate stream_command(command, env, workdir, config, opts), to: Execution
  @doc false
  defdelegate list_all_files(dir), to: Uploads

  @impl true
  def stop_commands(job_id, agents), do: Ownership.terminate_agents(job_id, agents)

  @impl true
  def run(payload, config, opts \\ []) do
    runner_name = Context.build_runner_name(config, opts)

    base_dir =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_host_local_#{runner_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = Context.build_message(payload, config, opts)

    try do
      with :ok <- Uploads.copy_uploads(base_dir, config, opts),
           {:ok, python_env} <- PythonEnvironment.ensure_python_environment(config, opts),
           :ok <- Context.write_runtime_files(base_dir, message, opts),
           {command, env, workdir} <-
             Command.build_command(config, base_dir, opts, message, python_env),
           {:ok, output, exit_code} <-
             Execution.run_command(command, env, workdir, config, opts, message),
           {:ok, result} <- Output.extract_result(output, exit_code, runner_name, workdir) do
        if result["exit_code"] == 0 do
          {:ok, result}
        else
          {:error, result}
        end
      end
    after
      File.rm_rf(base_dir)
    end
  end
end
