defmodule MirrorNeuron.Runner.HostLocal.Context do
  @moduledoc "Invocation messages, runtime files and environment identity."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Message

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
                 workflow: workflow_context(message),
                 timestamp: MirrorNeuron.Runtime.timestamp()
               },
               pretty: true
             )
           ) do
      :ok
    end
  end

  def get_config(config, key) when is_map(config) do
    MirrorNeuron.SafeAccess.map_get(config, key)
  end

  def runtime_env(input_file, context_file, message_file, body_file, workdir, message, opts) do
    %{
      "MN_INPUT_FILE" => input_file,
      "MN_CONTEXT_FILE" => context_file,
      "MN_MESSAGE_FILE" => message_file,
      "MN_BODY_FILE" => body_file,
      "MN_BODY_CONTENT_TYPE" => Message.content_type(message),
      "MN_BODY_CONTENT_ENCODING" => Message.content_encoding(message),
      "MN_AGENT_TYPE" => to_string(Keyword.get(opts, :agent_type, "")),
      "MN_AGENT_TEMPLATE" => Keyword.get(opts, :template_type, "generic"),
      "MN_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
      "MN_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
      "MN_GRPC_TARGET" => "127.0.0.1:#{Config.integer("MN_GRPC_PORT", :grpc_port)}",
      "MN_WORKDIR" => workdir
    }
  end

  def workflow_context(nil), do: %{}

  def workflow_context(message) do
    headers = Message.headers(message)

    %{
      "run_id" => Map.get(headers, "mn.workflow.run_id"),
      "step_id" => Map.get(headers, "mn.workflow.step_id"),
      "graph_revision" => Map.get(headers, "mn.workflow.graph_revision"),
      "template_id" => Map.get(headers, "mn.workflow.template_id"),
      "region_id" => Map.get(headers, "mn.workflow.region_id"),
      "attempt_id" => Map.get(headers, "mn.workflow.attempt_id"),
      "attempt" => Map.get(headers, "mn.workflow.attempt"),
      "deadline_at" => Map.get(headers, "mn.workflow.deadline_at"),
      "heartbeat_deadline_at" => Map.get(headers, "mn.workflow.heartbeat_deadline_at"),
      "idempotency_key" => Map.get(headers, "mn.workflow.idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def extra_env(config) do
    explicit =
      config
      |> Map.get("environment", %{})
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)

    passthrough =
      config
      |> Map.get("pass_env", [])
      |> Enum.reduce(%{}, fn key, acc ->
        env_key = to_string(key)

        case System.get_env(env_key) do
          nil -> acc
          value -> Map.put(acc, env_key, value)
        end
      end)

    Map.merge(explicit, passthrough)
  end

  def build_runner_name(config, opts) do
    prefix = Map.get(config, "name_prefix", "host-local")
    job_id = Keyword.get(opts, :job_id, "job")
    agent_id = Keyword.get(opts, :agent_id, "agent")

    [prefix, job_id, agent_id]
    |> Enum.join("-")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim("-")
  end
end
