defmodule MirrorNeuron.Runner.OpenShell.Workspace do
  @moduledoc "Stages invocation files and message identity in a temporary local workspace."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.OpenShell.Settings
  alias MirrorNeuron.Runner.OpenShell.Uploads

  @doc false
  def stage_workspace(payload, config, opts) do
    sandbox_name =
      if Settings.reuse_shared_sandbox?(config) do
        "shared-#{Keyword.get(opts, :job_id, "job")}"
      else
        Settings.build_sandbox_name(config, opts)
      end

    base_dir =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_#{sandbox_name}_#{System.unique_integer([:positive])}"
      )

    case write_runtime_files(base_dir, payload, config, opts) do
      :ok ->
        {:ok, base_dir}

      {:error, _reason} = error ->
        File.rm_rf(base_dir)
        error
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp write_runtime_files(base_dir, payload, config, opts) do
    File.mkdir_p!(base_dir)
    message = build_message(payload, config, opts)

    with :ok <- Uploads.copy_uploads(base_dir, config, opts),
         :ok <-
           File.cp(
             Path.join(MirrorNeuron.Runner.OpenShellArtifactStore.helper_dir(), "supervision.py"),
             Path.join(base_dir, "mirror_neuron_supervision.py")
           ),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_input.json"),
             Jason.encode!(Message.body(message), pretty: true)
           ),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_message.json"),
             Jason.encode!(message, pretty: true)
           ),
         {:ok, body_binary} <- Message.body_binary(message),
         :ok <- File.write(Path.join(base_dir, "mirror_neuron_body.bin"), body_binary),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_body_meta.json"),
             Jason.encode!(
               %{
                 content_type: Message.content_type(message),
                 content_encoding: Message.content_encoding(message)
               },
               pretty: true
             )
           ),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_context.json"),
             Jason.encode!(
               %{
                 job_id: Keyword.get(opts, :job_id),
                 agent_id: Keyword.get(opts, :agent_id),
                 agent_type: Keyword.get(opts, :agent_type),
                 template_type: Keyword.get(opts, :template_type, "generic"),
                 agent_state: Keyword.get(opts, :agent_state, %{}),
                 timestamp: MirrorNeuron.Runtime.timestamp()
               },
               pretty: true
             )
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  def build_message(payload, config, opts) do
    case Keyword.get(opts, :message) do
      nil ->
        Message.new(
          Keyword.get(opts, :job_id),
          "runtime",
          Keyword.get(opts, :agent_id),
          Map.get(config, "output_message_type", "executor_input"),
          payload,
          content_type: Map.get(config, "content_type", "application/json"),
          content_encoding: Map.get(config, "content_encoding", "identity")
        )

      message ->
        Message.normalize!(
          message,
          job_id: Keyword.get(opts, :job_id),
          to: Keyword.get(opts, :agent_id),
          content_type: Map.get(config, "content_type", "application/json"),
          content_encoding: Map.get(config, "content_encoding", "identity")
        )
    end
  end
end
