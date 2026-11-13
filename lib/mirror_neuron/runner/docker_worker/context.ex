defmodule MirrorNeuron.Runner.DockerWorker.Context do
  @moduledoc "Invocation message files and fenced container runtime environment."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.DockerWorker.Settings

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

  def write_runtime_files(base_dir, message, opts) do
    with :ok <-
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
    end
  end

  def runtime_env(
        container_workdir,
        payloads_dir,
        config,
        opts,
        bundle_root
      ) do
    allocation =
      Keyword.get(opts, :allocation) || Map.get(config, "__mirror_neuron_allocation", %{})

    base = %{
      "MN_INPUT_FILE" => "#{bundle_root}/mirror_neuron_input.json",
      "MN_CONTEXT_FILE" => "#{bundle_root}/mirror_neuron_context.json",
      "MN_MESSAGE_FILE" => "#{bundle_root}/mirror_neuron_message.json",
      "MN_BODY_FILE" => "#{bundle_root}/mirror_neuron_body.bin",
      "MN_WORKDIR" => container_workdir,
      "MN_BUNDLE_ROOT" => bundle_root,
      "MN_PAYLOADS_DIR" => payloads_dir,
      "MN_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
      "MN_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
      "MN_AGENT_TYPE" => to_string(Keyword.get(opts, :agent_type, "")),
      "MN_RUNTIME_DRIVER" => "docker_worker"
    }

    base
    |> Map.merge(MirrorNeuron.ResourceSpec.allocation_env(allocation))
    |> Map.merge(Settings.extra_env(config))
    |> Map.merge(MirrorNeuron.Runner.WorkflowEnvironment.from_options(opts))
    |> Map.put("MN_EXECUTION_NODE", to_string(Node.self()))
    |> MirrorNeuron.Runner.ContextEnvironment.bind()
    |> MirrorNeuron.Runner.CoreEnvironment.docker_worker(
      System.get_env(),
      MirrorNeuron.Grpc.Tokens.auth_token()
    )
  end
end
