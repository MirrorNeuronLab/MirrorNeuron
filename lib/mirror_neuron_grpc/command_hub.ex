defmodule MirrorNeuron.Grpc.Errors do
  @moduledoc false

  require Logger

  def raise_unexpected!(error, stacktrace, metadata) do
    Logger.error("gRPC command failed unexpectedly (#{error_type(error)})",
      grpc_error_type: error_type(error),
      grpc_command_service: metadata[:service],
      grpc_command: metadata[:command]
    )

    reraise GRPC.RPCError,
            [
              status: GRPC.Status.internal(),
              message: Exception.message(error)
            ],
            stacktrace
  end

  defp error_type(%{__struct__: struct}), do: inspect(struct)
  defp error_type(_error), do: "unknown"
end

defmodule MirrorNeuron.Grpc.Validation do
  @moduledoc false

  def decode_json(nil, default), do: {:ok, default}
  def decode_json("", default), do: {:ok, default}

  def decode_json(json, _default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "body must be valid JSON: #{Exception.message(error)}"}
    end
  end

  def decode_json(_json, _default), do: {:error, "body must be valid JSON"}

  def decode_json_map(json, default \\ %{}) do
    case decode_json(json, default) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "body must be a JSON object"}
      {:error, reason} -> {:error, reason}
    end
  end

  def required_string(value, field) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, "#{field} is required"}, else: {:ok, value}
  end

  def required_string(_value, field), do: {:error, "#{field} is required"}

  def optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def optional_string(value) when is_nil(value), do: nil
  def optional_string(value), do: value |> to_string() |> optional_string()

  def positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  def positive_integer(_value, default), do: default

  def safe_payload_path(payloads_dir, path) when is_binary(path) do
    payloads_root = Path.expand(payloads_dir)
    expanded = Path.expand(path, payloads_root)

    cond do
      path == "" or Path.type(path) != :relative or ".." in Path.split(path) ->
        {:error, "payload path must be relative and stay inside payloads/: #{inspect(path)}"}

      expanded == payloads_root or not String.starts_with?(expanded, payloads_root <> "/") ->
        {:error, "payload path must stay inside payloads/: #{inspect(path)}"}

      true ->
        {:ok, expanded}
    end
  end

  def safe_payload_path(_payloads_dir, path) do
    {:error, "payload path must be a string: #{inspect(path)}"}
  end
end

defmodule MirrorNeuron.Grpc.CommandPolicy do
  @moduledoc false

  @network_only_denied MapSet.new([
                         {:job, :CreateJob},
                         {:job, :GetJob},
                         {:job, :ListJobs},
                         {:job, :UpdateJob},
                         {:job, :ArchiveJob},
                         {:job, :ResetJobData},
                         {:job, :DeleteJob},
                         {:job, :StartRun},
                         {:job, :ListRuns},
                         {:job, :GetRun},
                         {:job, :PauseRun},
                         {:job, :ResumeRun},
                         {:job, :CancelRun},
                         {:job, :DeleteRun},
                         {:job, :SendRunInput},
                         {:job, :CreateJobSchedule},
                         {:job, :QueryJobResponse},
                         {:cluster, :SetResource},
                         {:cluster, :AddNode},
                         {:cluster, :RemoveNode},
                         {:cluster, :ReconcileNode},
                         {:cluster, :DrainNode},
                         {:cluster, :CancelNodeDrain},
                         {:cluster, :SetNodeMaintenance},
                         {:cluster, :GetNodeDrainStatus},
                         {:cluster, :ListServices},
                         {:cluster, :ResolveService},
                         {:cluster, :CheckServices},
                         {:operations, :StartOperation},
                         {:operations, :GetOperation},
                         {:operations, :StreamOperationEvents},
                         {:cluster, :SyncLiteLLMGateway},
                         {:cluster, :RemoveLiteLLMGatewayRoute},
                         {:observability, :StreamEvents}
                       ])

  @network_join_auth_required MapSet.new([
                                {:cluster, :NetworkHandshake}
                              ])

  @identity_auth_required MapSet.new([
                            {:job, :CreateJob},
                            {:job, :GetJob},
                            {:job, :ListJobs},
                            {:job, :UpdateJob},
                            {:job, :ArchiveJob},
                            {:job, :ResetJobData},
                            {:job, :DeleteJob},
                            {:job, :StartRun},
                            {:job, :ListRuns},
                            {:job, :GetRun},
                            {:job, :PauseRun},
                            {:job, :ResumeRun},
                            {:job, :CancelRun},
                            {:job, :DeleteRun},
                            {:job, :SendRunInput},
                            {:job, :CreateJobSchedule},
                            {:job, :QueryJobResponse},
                            {:cluster, :ReconcileNode},
                            {:cluster, :DrainNode},
                            {:cluster, :CancelNodeDrain},
                            {:cluster, :SetNodeMaintenance},
                            {:cluster, :GetNodeDrainStatus},
                            {:cluster, :ListServices},
                            {:cluster, :ResolveService},
                            {:cluster, :CheckServices},
                            {:cluster, :GetRuntimeStatuses},
                            {:cluster, :RegisterFederatedPeer},
                            {:cluster, :GetFederatedPeer},
                            {:cluster, :RemoveFederatedPeer},
                            {:cluster, :PublishRuntimeStatus},
                            {:cluster, :AckRuntimeStatusEvents},
                            {:cluster, :SyncLiteLLMGateway},
                            {:cluster, :RemoveLiteLLMGatewayRoute},
                            {:operations, :StartOperation},
                            {:operations, :GetOperation},
                            {:operations, :StreamOperationEvents}
                          ])

  def enforce!(service, command, _request, stream) do
    if network_only_denied?(service, command) do
      MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!(command_name(command))
    end

    if identity_auth_required?(service, command) do
      MirrorNeuron.Grpc.Auth.authorize_identity!(stream)
    end

    :ok
  end

  def policies(service, command) do
    %{
      network_only_denied: network_only_denied?(service, command),
      identity_auth_required: identity_auth_required?(service, command),
      network_join_auth_required: MapSet.member?(@network_join_auth_required, {service, command})
    }
  end

  def network_only_denied?(service, command) do
    MapSet.member?(@network_only_denied, {service, command})
  end

  defp identity_auth_required?(service, command) do
    MapSet.member?(@identity_auth_required, {service, command})
  end

  defp command_name(command) when is_atom(command), do: Atom.to_string(command)
  defp command_name(command), do: to_string(command)
end

defmodule MirrorNeuron.Grpc.CommandHub do
  @moduledoc false

  require Logger

  @default_modules %{}
                   |> Map.merge(
                     Map.new(
                       [
                         :CreateJob,
                         :GetJob,
                         :ListJobs,
                         :UpdateJob,
                         :ArchiveJob,
                         :ResetJobData,
                         :DeleteJob,
                         :StartRun,
                         :ListRuns,
                         :GetRun,
                         :PauseRun,
                         :ResumeRun,
                         :CancelRun,
                         :DeleteRun,
                         :SendRunInput,
                         :CreateJobSchedule,
                         :QueryJobResponse
                       ],
                       &{{:job, &1}, MirrorNeuron.Grpc.Handlers.Job}
                     )
                   )
                   |> Map.merge(%{
                     {:cluster, :NetworkHandshake} => MirrorNeuron.Grpc.Handlers.ClusterHandshake,
                     {:cluster, :GetSystemSummary} => MirrorNeuron.Grpc.Handlers.Resource,
                     {:cluster, :GetResource} => MirrorNeuron.Grpc.Handlers.Resource,
                     {:cluster, :SetResource} => MirrorNeuron.Grpc.Handlers.Resource,
                     {:cluster, :GetRuntimeStatuses} => MirrorNeuron.Grpc.Handlers.RuntimeStatus,
                     {:cluster, :PublishRuntimeStatus} =>
                       MirrorNeuron.Grpc.Handlers.RuntimeStatus,
                     {:cluster, :AckRuntimeStatusEvents} =>
                       MirrorNeuron.Grpc.Handlers.RuntimeStatus,
                     {:cluster, :SyncLiteLLMGateway} => MirrorNeuron.Grpc.Handlers.RuntimeModel,
                     {:cluster, :RemoveLiteLLMGatewayRoute} =>
                       MirrorNeuron.Grpc.Handlers.RuntimeModel,
                     {:cluster, :PrepareRuntimeModel} => MirrorNeuron.Grpc.Handlers.RuntimeModel,
                     {:cluster, :PrepareDockerWorker} => MirrorNeuron.Grpc.Handlers.DockerWorker,
                     {:cluster, :CleanupDockerWorker} => MirrorNeuron.Grpc.Handlers.DockerWorker,
                     {:cluster, :PrepareDockerCompose} =>
                       MirrorNeuron.Grpc.Handlers.DockerCompose,
                     {:cluster, :GetDockerComposeStatus} =>
                       MirrorNeuron.Grpc.Handlers.DockerCompose,
                     {:cluster, :CleanupDockerCompose} => MirrorNeuron.Grpc.Handlers.DockerCompose
                   })
                   |> Map.merge(
                     Map.new(
                       [
                         :AddNode,
                         :RemoveNode,
                         :RegisterFederatedPeer,
                         :GetFederatedPeer,
                         :RemoveFederatedPeer,
                         :ReconcileNode,
                         :DrainNode,
                         :CancelNodeDrain,
                         :SetNodeMaintenance,
                         :GetNodeDrainStatus
                       ],
                       &{{:cluster, &1}, MirrorNeuron.Grpc.Handlers.Node}
                     )
                   )
                   |> Map.merge(
                     Map.new(
                       [
                         :ListServices,
                         :ResolveService,
                         :CheckServices
                       ],
                       &{{:cluster, &1}, MirrorNeuron.Grpc.Handlers.Service}
                     )
                   )
                   |> Map.put(
                     {:observability, :StreamEvents},
                     MirrorNeuron.Grpc.Handlers.Observability
                   )
                   |> Map.merge(
                     Map.new(
                       [:StartOperation, :GetOperation, :StreamOperationEvents],
                       &{{:operations, &1}, MirrorNeuron.Grpc.Handlers.Operation}
                     )
                   )

  @safe_identifier_keys [
    :job_id,
    :operation_id,
    :node_name,
    :schedule_id,
    :id_or_key,
    :deployment_key,
    :name,
    :event_type
  ]

  def dispatch(service, command, request, stream) when is_atom(service) and is_atom(command) do
    started = System.monotonic_time()
    module = command_module(service, command)
    function = command_function(command)
    metadata = [service: service, command: command]

    log_start(service, command, request)

    try do
      MirrorNeuron.Grpc.CommandPolicy.enforce!(service, command, request, stream)
      response = apply(module, function, [request, stream])
      log_finish(:ok, service, command, request, started)
      response
    rescue
      error in GRPC.RPCError ->
        log_finish(:error, service, command, request, started, error)
        reraise error, __STACKTRACE__

      error ->
        log_finish(:error, service, command, request, started, error)
        MirrorNeuron.Grpc.Errors.raise_unexpected!(error, __STACKTRACE__, metadata)
    end
  end

  def command_module(service, command) do
    deps = Application.get_env(:mirror_neuron, :grpc_command_dependencies, %{})

    Map.get(deps, {service, command}) ||
      Map.get(deps, command) ||
      Map.get(deps, service) ||
      Map.fetch!(@default_modules, {service, command})
  end

  def command_function(command) when is_atom(command) do
    command
    |> Atom.to_string()
    |> Macro.underscore()
    |> String.to_atom()
  end

  def command_function(command) when is_binary(command) do
    command
    |> Macro.underscore()
    |> String.to_atom()
  end

  def default_modules, do: @default_modules

  defp log_start(service, command, request) do
    Logger.debug("gRPC command start",
      grpc_command_service: service,
      grpc_command: command,
      grpc_identifiers: safe_identifiers(request)
    )
  end

  defp log_finish(status, service, command, request, started, error \\ nil) do
    duration_ms =
      System.monotonic_time()
      |> Kernel.-(started)
      |> System.convert_time_unit(:native, :millisecond)

    Logger.info(
      "gRPC command finish",
      [
        grpc_command_service: service,
        grpc_command: command,
        grpc_command_status: status,
        grpc_duration_ms: duration_ms,
        grpc_identifiers: safe_identifiers(request)
      ] ++ safe_error_metadata(error)
    )
  end

  defp safe_error_metadata(nil), do: []

  defp safe_error_metadata(%GRPC.RPCError{} = error) do
    [
      grpc_error_type: inspect(GRPC.RPCError),
      grpc_error_status: Map.get(error, :status)
    ]
  end

  defp safe_error_metadata(%{__struct__: struct}), do: [grpc_error_type: inspect(struct)]
  defp safe_error_metadata(_error), do: [grpc_error_type: "unknown"]

  defp safe_identifiers(request) when is_map(request) do
    @safe_identifier_keys
    |> Enum.flat_map(fn key ->
      value = Map.get(request, key)
      if value in [nil, ""], do: [], else: [{key, value}]
    end)
    |> Map.new()
  end

  defp safe_identifiers(_request), do: %{}
end
