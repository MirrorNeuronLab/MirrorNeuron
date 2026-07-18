defmodule MirrorNeuron.Grpc.JobServer do
  use GRPC.Server, service: Mirrorneuron.Job.V1.JobService.Service

  for {function, command} <- [
        submit_job: :SubmitJob,
        get_job: :GetJob,
        list_jobs: :ListJobs,
        cancel_job: :CancelJob,
        cancel_all_jobs: :CancelAllJobs,
        pause_job: :PauseJob,
        resume_job: :ResumeJob,
        export_job_backup: :ExportJobBackup,
        restore_job_backup: :RestoreJobBackup,
        clear_jobs: :ClearJobs,
        deploy_job: :DeployJob,
        update_deployment: :UpdateDeployment,
        get_deployment: :GetDeployment,
        list_deployments: :ListDeployments,
        promote_deployment: :PromoteDeployment,
        rollback_deployment: :RollbackDeployment,
        pause_deployment: :PauseDeployment,
        resume_deployment: :ResumeDeployment,
        fail_deployment: :FailDeployment,
        create_schedule: :CreateSchedule,
        update_schedule: :UpdateSchedule,
        get_schedule: :GetSchedule,
        list_schedules: :ListSchedules,
        pause_schedule: :PauseSchedule,
        resume_schedule: :ResumeSchedule,
        delete_schedule: :DeleteSchedule,
        dispatch_schedule: :DispatchSchedule,
        emit_trigger_event: :EmitTriggerEvent,
        list_trigger_events: :ListTriggerEvents
      ] do
    def unquote(function)(request, stream) do
      MirrorNeuron.Grpc.CommandHub.dispatch(:job, unquote(command), request, stream)
    end
  end
end

defmodule MirrorNeuron.Grpc.ClusterServer do
  use GRPC.Server, service: Mirrorneuron.Cluster.V1.ClusterService.Service

  for {function, command} <- [
        network_handshake: :NetworkHandshake,
        get_system_summary: :GetSystemSummary,
        get_resource: :GetResource,
        set_resource: :SetResource,
        get_runtime_statuses: :GetRuntimeStatuses,
        publish_runtime_status: :PublishRuntimeStatus,
        ack_runtime_status_events: :AckRuntimeStatusEvents,
        sync_lite_llm_gateway: :SyncLiteLLMGateway,
        remove_lite_llm_gateway_route: :RemoveLiteLLMGatewayRoute,
        prepare_runtime_model: :PrepareRuntimeModel,
        prepare_docker_worker: :PrepareDockerWorker,
        cleanup_docker_worker: :CleanupDockerWorker,
        add_node: :AddNode,
        remove_node: :RemoveNode,
        reconcile_node: :ReconcileNode,
        drain_node: :DrainNode,
        cancel_node_drain: :CancelNodeDrain,
        set_node_maintenance: :SetNodeMaintenance,
        get_node_drain_status: :GetNodeDrainStatus,
        list_services: :ListServices,
        resolve_service: :ResolveService,
        check_services: :CheckServices
      ] do
    def unquote(function)(request, stream) do
      MirrorNeuron.Grpc.CommandHub.dispatch(:cluster, unquote(command), request, stream)
    end
  end

  defdelegate set_peer_cookie(node_name, cookie_text), to: MirrorNeuron.Grpc.Handlers.Node
  defdelegate connect_peer(node_name), to: MirrorNeuron.Grpc.Handlers.Node
  defdelegate disconnect_peer(node_name), to: MirrorNeuron.Grpc.Handlers.Node
  defdelegate disconnect_peers(node_names), to: MirrorNeuron.Grpc.Handlers.Node
  defdelegate confirm_join_claim(owner_node_name), to: MirrorNeuron.Grpc.Handlers.Node
  defdelegate clear_join_claim(owner_node_name), to: MirrorNeuron.Grpc.Handlers.Node
  defdelegate node_advertisement_info, to: MirrorNeuron.Grpc.Handlers.ClusterHandshake
end

defmodule MirrorNeuron.Grpc.ObservabilityServer do
  use GRPC.Server, service: Mirrorneuron.Observability.V1.ObservabilityService.Service

  def stream_events(request, stream) do
    MirrorNeuron.Grpc.CommandHub.dispatch(:observability, :StreamEvents, request, stream)
  end
end

defmodule MirrorNeuron.Grpc.Endpoint do
  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(MirrorNeuron.Grpc.JobServer)
  run(MirrorNeuron.Grpc.ClusterServer)
  run(MirrorNeuron.Grpc.ObservabilityServer)
end
