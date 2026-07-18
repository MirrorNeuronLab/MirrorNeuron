defmodule MirrorNeuron.Grpc.CommandHubTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MirrorNeuron.Grpc.{
    ClusterServer,
    CommandHub,
    CommandPolicy,
    JobServer,
    ObservabilityServer
  }

  alias Mirrorneuron.Cluster.V1.{
    AddNodeRequest,
    AddNodeResponse,
    CancelNodeDrainRequest,
    CancelNodeDrainResponse,
    CheckServicesRequest,
    CheckServicesResponse,
    CleanupDockerWorkerRequest,
    CleanupDockerWorkerResponse,
    DrainNodeRequest,
    DrainNodeResponse,
    GetNodeDrainStatusRequest,
    GetNodeDrainStatusResponse,
    GetResourceRequest,
    GetResourceResponse,
    GetSystemSummaryRequest,
    GetSystemSummaryResponse,
    ListServicesRequest,
    ListServicesResponse,
    NetworkHandshakeRequest,
    NetworkHandshakeResponse,
    PrepareDockerWorkerRequest,
    PrepareDockerWorkerResponse,
    ReconcileNodeRequest,
    ReconcileNodeResponse,
    RemoveNodeRequest,
    RemoveNodeResponse,
    ResolveServiceRequest,
    ResolveServiceResponse,
    SetNodeMaintenanceRequest,
    SetNodeMaintenanceResponse,
    SetResourceRequest,
    SetResourceResponse
  }

  alias Mirrorneuron.Job.V1.{
    CancelAllJobsRequest,
    CancelAllJobsResponse,
    CancelJobRequest,
    CancelJobResponse,
    ClearJobsRequest,
    ClearJobsResponse,
    CreateScheduleRequest,
    DeploymentActionRequest,
    DeploymentResponse,
    DispatchScheduleRequest,
    EmitTriggerEventRequest,
    ExportJobBackupRequest,
    ExportJobBackupResponse,
    GetDeploymentRequest,
    GetJobRequest,
    GetJobResponse,
    GetScheduleRequest,
    ListDeploymentsRequest,
    ListJobsRequest,
    ListJobsResponse,
    ListSchedulesRequest,
    ListTriggerEventsRequest,
    PauseJobRequest,
    PauseJobResponse,
    PromoteDeploymentRequest,
    RestoreJobBackupRequest,
    RestoreJobBackupResponse,
    ResumeJobRequest,
    ResumeJobResponse,
    RollbackDeploymentRequest,
    ScheduleActionRequest,
    ScheduleResponse,
    SubmitJobRequest,
    SubmitJobResponse,
    UpdateDeploymentRequest
  }

  alias Mirrorneuron.Observability.V1.StreamEventsRequest

  @test_pid_name :grpc_command_hub_test_pid
  @identity_token "command-hub-identity"

  defmodule AuthenticatedStream do
    defstruct headers: %{}
  end

  defmodule FakeJobCommands do
    @test_pid_name :grpc_command_hub_test_pid

    def submit_job(request, stream),
      do:
        reply(:submit_job, request, stream, %SubmitJobResponse{
          job_id: "job-1",
          status: "pending",
          version: 1
        })

    def get_job(request, stream),
      do: reply(:get_job, request, stream, %GetJobResponse{job_json: "{}", version: 1})

    def list_jobs(request, stream),
      do:
        reply(:list_jobs, request, stream, %ListJobsResponse{
          jobs_json: "{\"data\":[]}",
          version: 1
        })

    def cancel_job(request, stream),
      do:
        reply(:cancel_job, request, stream, %CancelJobResponse{
          job_id: request.job_id,
          status: "cancelled",
          version: 1
        })

    def cancel_all_jobs(request, stream),
      do:
        reply(:cancel_all_jobs, request, stream, %CancelAllJobsResponse{
          result_json: "{\"cancelled_count\":0,\"failed_count\":0,\"results\":[]}",
          version: 1
        })

    def pause_job(request, stream),
      do:
        reply(:pause_job, request, stream, %PauseJobResponse{
          job_id: request.job_id,
          status: "paused",
          version: 1
        })

    def resume_job(request, stream),
      do:
        reply(:resume_job, request, stream, %ResumeJobResponse{
          job_id: request.job_id,
          status: "running",
          version: 1
        })

    def export_job_backup(request, stream),
      do:
        reply(:export_job_backup, request, stream, %ExportJobBackupResponse{
          backup_json: "{}",
          bundle_files: %{},
          version: 1
        })

    def restore_job_backup(request, stream),
      do:
        reply(:restore_job_backup, request, stream, %RestoreJobBackupResponse{
          result_json: "{}",
          version: 1
        })

    def clear_jobs(request, stream),
      do: reply(:clear_jobs, request, stream, %ClearJobsResponse{cleared_count: 1, version: 1})

    def deploy_job(request, stream), do: deployment_reply(:deploy_job, request, stream)

    def update_deployment(request, stream),
      do: deployment_reply(:update_deployment, request, stream)

    def get_deployment(request, stream), do: deployment_reply(:get_deployment, request, stream)

    def list_deployments(request, stream),
      do: deployment_reply(:list_deployments, request, stream)

    def promote_deployment(request, stream),
      do: deployment_reply(:promote_deployment, request, stream)

    def rollback_deployment(request, stream),
      do: deployment_reply(:rollback_deployment, request, stream)

    def pause_deployment(request, stream),
      do: deployment_reply(:pause_deployment, request, stream)

    def resume_deployment(request, stream),
      do: deployment_reply(:resume_deployment, request, stream)

    def fail_deployment(request, stream), do: deployment_reply(:fail_deployment, request, stream)
    def create_schedule(request, stream), do: schedule_reply(:create_schedule, request, stream)
    def update_schedule(request, stream), do: schedule_reply(:update_schedule, request, stream)
    def get_schedule(request, stream), do: schedule_reply(:get_schedule, request, stream)
    def list_schedules(request, stream), do: schedule_reply(:list_schedules, request, stream)
    def pause_schedule(request, stream), do: schedule_reply(:pause_schedule, request, stream)
    def resume_schedule(request, stream), do: schedule_reply(:resume_schedule, request, stream)
    def delete_schedule(request, stream), do: schedule_reply(:delete_schedule, request, stream)

    def dispatch_schedule(request, stream),
      do: schedule_reply(:dispatch_schedule, request, stream)

    def emit_trigger_event(request, stream),
      do: schedule_reply(:emit_trigger_event, request, stream)

    def list_trigger_events(request, stream),
      do: schedule_reply(:list_trigger_events, request, stream)

    defp deployment_reply(command, request, stream),
      do: reply(command, request, stream, %DeploymentResponse{result_json: "{}", version: 1})

    defp schedule_reply(command, request, stream),
      do: reply(command, request, stream, %ScheduleResponse{result_json: "{}", version: 1})

    defp reply(command, request, stream, response) do
      notify({:called, :job, command, request, stream})
      response
    end

    defp notify(message) do
      if pid = Process.whereis(@test_pid_name), do: send(pid, message)
    end
  end

  defmodule FakeClusterCommands do
    @test_pid_name :grpc_command_hub_test_pid

    def network_handshake(request, stream),
      do:
        reply(:network_handshake, request, stream, %NetworkHandshakeResponse{
          node_name: "mirror@test",
          version: 1
        })

    def get_system_summary(request, stream),
      do:
        reply(:get_system_summary, request, stream, %GetSystemSummaryResponse{
          summary_json: "{}",
          version: 1
        })

    def get_resource(request, stream),
      do:
        reply(:get_resource, request, stream, %GetResourceResponse{
          resource_json: "{}",
          version: 1
        })

    def set_resource(request, stream),
      do:
        reply(:set_resource, request, stream, %SetResourceResponse{
          resource_json: "{}",
          version: 1
        })

    def get_runtime_statuses(request, stream),
      do:
        reply(:get_runtime_statuses, request, stream, %GetResourceResponse{
          resource_json: "{\"nodes\":[]}",
          version: 1
        })

    def publish_runtime_status(request, stream),
      do:
        reply(:publish_runtime_status, request, stream, %SetResourceResponse{
          resource_json: "{\"status\":\"accepted\"}",
          version: 1
        })

    def ack_runtime_status_events(request, stream),
      do:
        reply(:ack_runtime_status_events, request, stream, %SetResourceResponse{
          resource_json: "{\"status\":\"acked\"}",
          version: 1
        })

    def sync_lite_llm_gateway(request, stream),
      do:
        reply(:sync_lite_llm_gateway, request, stream, %SetResourceResponse{
          resource_json: "{\"status\":\"running\"}",
          version: 1
        })

    def remove_lite_llm_gateway_route(request, stream),
      do:
        reply(:remove_lite_llm_gateway_route, request, stream, %SetResourceResponse{
          resource_json: "{\"status\":\"removed\"}",
          version: 1
        })

    def prepare_runtime_model(request, stream),
      do:
        reply(:prepare_runtime_model, request, stream, %SetResourceResponse{
          resource_json: "{\"status\":\"installed\"}",
          version: 1
        })

    def prepare_docker_worker(request, stream),
      do:
        reply(:prepare_docker_worker, request, stream, %PrepareDockerWorkerResponse{
          result_json: "{\"prepared\":true}",
          version: 1
        })

    def cleanup_docker_worker(request, stream),
      do:
        reply(:cleanup_docker_worker, request, stream, %CleanupDockerWorkerResponse{
          result_json: "{\"removed\":1}",
          version: 1
        })

    def add_node(request, stream),
      do:
        reply(:add_node, request, stream, %AddNodeResponse{
          node_name: request.node_name,
          status: "connected",
          version: 1
        })

    def remove_node(request, stream),
      do:
        reply(:remove_node, request, stream, %RemoveNodeResponse{
          node_name: request.node_name,
          status: "removed",
          version: 1
        })

    def reconcile_node(request, stream),
      do:
        reply(:reconcile_node, request, stream, %ReconcileNodeResponse{
          result_json: "{}",
          version: 1
        })

    def drain_node(request, stream),
      do: reply(:drain_node, request, stream, %DrainNodeResponse{result_json: "{}", version: 1})

    def cancel_node_drain(request, stream),
      do:
        reply(:cancel_node_drain, request, stream, %CancelNodeDrainResponse{
          result_json: "{}",
          version: 1
        })

    def set_node_maintenance(request, stream),
      do:
        reply(:set_node_maintenance, request, stream, %SetNodeMaintenanceResponse{
          result_json: "{}",
          version: 1
        })

    def get_node_drain_status(request, stream),
      do:
        reply(:get_node_drain_status, request, stream, %GetNodeDrainStatusResponse{
          result_json: "{}",
          version: 1
        })

    def list_services(request, stream),
      do:
        reply(:list_services, request, stream, %ListServicesResponse{
          result_json: "{}",
          version: 1
        })

    def resolve_service(request, stream),
      do:
        reply(:resolve_service, request, stream, %ResolveServiceResponse{
          result_json: "{}",
          version: 1
        })

    def check_services(request, stream),
      do:
        reply(:check_services, request, stream, %CheckServicesResponse{
          result_json: "{}",
          version: 1
        })

    defp reply(command, request, stream, response) do
      notify({:called, :cluster, command, request, stream})
      response
    end

    defp notify(message) do
      if pid = Process.whereis(@test_pid_name), do: send(pid, message)
    end
  end

  defmodule FakeObservabilityCommands do
    @test_pid_name :grpc_command_hub_test_pid

    def stream_events(request, stream) do
      if pid = Process.whereis(@test_pid_name),
        do: send(pid, {:called, :observability, :stream_events, request, stream})

      :streamed
    end
  end

  defmodule RuntimeErrorCommands do
    def get_job(_request, _stream), do: raise("boom")
  end

  defmodule RpcErrorCommands do
    def get_job(_request, _stream) do
      raise GRPC.RPCError, status: GRPC.Status.invalid_argument(), message: "bad request"
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)
    previous = Application.get_env(:mirror_neuron, :grpc_command_dependencies)
    previous_network_only_env = System.get_env("MN_NETWORK_ONLY")
    previous_network_only_app = Application.get_env(:mirror_neuron, :network_only)
    previous_auth_token = System.get_env("MN_GRPC_AUTH_TOKEN")

    System.delete_env("MN_NETWORK_ONLY")
    System.put_env("MN_GRPC_AUTH_TOKEN", @identity_token)
    Application.put_env(:mirror_neuron, :network_only, false)

    on_exit(fn ->
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      restore_app_env(:grpc_command_dependencies, previous)
      restore_app_env(:network_only, previous_network_only_app)
      restore_system_env("MN_NETWORK_ONLY", previous_network_only_env)
      restore_system_env("MN_GRPC_AUTH_TOKEN", previous_auth_token)
    end)

    :ok
  end

  test "server adapters route every RPC through injected command modules" do
    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{
      job: FakeJobCommands,
      cluster: FakeClusterCommands,
      observability: FakeObservabilityCommands
    })

    for %{
          service: service,
          server: server,
          function: function,
          request: request,
          response: response
        } <- rpc_cases() do
      stream = authenticated_stream()
      result = apply(server, function, [request, stream])

      if response == :streamed do
        assert result == :streamed
      else
        assert match?(%{__struct__: ^response}, result)
      end

      assert_receive {:called, ^service, ^function, ^request, ^stream}
    end
  end

  test "default command registry covers every runtime RPC without dependency injection" do
    Application.delete_env(:mirror_neuron, :grpc_command_dependencies)

    for %{service: service, command: command, function: function} <- rpc_cases() do
      module = CommandHub.command_module(service, command)
      assert module == Map.fetch!(CommandHub.default_modules(), {service, command})
      Code.ensure_loaded!(module)
      assert function_exported?(module, function, 2)
    end
  end

  test "policy registry describes network-only and auth requirements" do
    assert CommandPolicy.policies(:job, :SubmitJob) == %{
             network_only_denied: true,
             identity_auth_required: false,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:job, :PauseJob) == %{
             network_only_denied: true,
             identity_auth_required: true,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:job, :ClearJobs) == %{
             network_only_denied: true,
             identity_auth_required: true,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :NetworkHandshake) == %{
             network_only_denied: false,
             identity_auth_required: false,
             network_join_auth_required: true
           }

    assert CommandPolicy.policies(:cluster, :PrepareRuntimeModel) == %{
             network_only_denied: false,
             identity_auth_required: false,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :PrepareDockerWorker) == %{
             network_only_denied: false,
             identity_auth_required: false,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :CleanupDockerWorker) == %{
             network_only_denied: false,
             identity_auth_required: false,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :GetRuntimeStatuses) == %{
             network_only_denied: false,
             identity_auth_required: true,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :PublishRuntimeStatus) == %{
             network_only_denied: false,
             identity_auth_required: true,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :AckRuntimeStatusEvents) == %{
             network_only_denied: false,
             identity_auth_required: true,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :SyncLiteLLMGateway) == %{
             network_only_denied: true,
             identity_auth_required: true,
             network_join_auth_required: false
           }

    assert CommandPolicy.policies(:cluster, :RemoveLiteLLMGatewayRoute) == %{
             network_only_denied: true,
             identity_auth_required: true,
             network_join_auth_required: false
           }
  end

  test "hub enforces network-only policy before injected commands run" do
    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{job: FakeJobCommands})
    System.put_env("MN_NETWORK_ONLY", "true")

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.submit_job(%SubmitJobRequest{}, :stream)
      end

    assert error.status == GRPC.Status.permission_denied()
    assert Exception.message(error) == "SubmitJob is disabled while MN_NETWORK_ONLY=true"
    refute_receive {:called, :job, :submit_job, _request, _stream}, 50
  end

  test "hub enforces one client identity policy before protected commands run" do
    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{job: FakeJobCommands})

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.pause_job(%PauseJobRequest{job_id: "job-1"}, nil)
      end

    assert error.status == GRPC.Status.unauthenticated()
    assert Exception.message(error) == "gRPC client identity is required for this RPC"
    refute_receive {:called, :job, :pause_job, _request, _stream}, 50
  end

  test "hub preserves explicit gRPC errors" do
    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{
      {:job, :GetJob} => RpcErrorCommands
    })

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.get_job(%GetJobRequest{job_id: "job-1"}, authenticated_stream())
      end

    assert error.status == GRPC.Status.invalid_argument()
    assert Exception.message(error) == "bad request"
  end

  test "hub normalizes unexpected dependency errors" do
    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{
      {:job, :GetJob} => RuntimeErrorCommands
    })

    log =
      capture_log(fn ->
        error =
          assert_raise GRPC.RPCError, fn ->
            JobServer.get_job(%GetJobRequest{job_id: "job-1"}, authenticated_stream())
          end

        assert error.status == GRPC.Status.internal()
        assert Exception.message(error) == "boom"
      end)

    assert log =~ "RuntimeError"
    refute log =~ "boom"
  end

  test "hub error logs omit unexpected exception messages" do
    defmodule SecretErrorCommands do
      def get_job(_request, _stream), do: raise("token=super-secret")
    end

    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{
      {:job, :GetJob} => SecretErrorCommands
    })

    log =
      capture_log(fn ->
        error =
          assert_raise GRPC.RPCError, fn ->
            JobServer.get_job(%GetJobRequest{job_id: "job-1"}, authenticated_stream())
          end

        assert error.status == GRPC.Status.internal()
        assert Exception.message(error) == "token=super-secret"
      end)

    refute log =~ "token=super-secret"
  end

  defp rpc_cases do
    [
      %{
        service: :job,
        command: :SubmitJob,
        server: JobServer,
        function: :submit_job,
        request: %SubmitJobRequest{},
        response: SubmitJobResponse
      },
      %{
        service: :job,
        command: :GetJob,
        server: JobServer,
        function: :get_job,
        request: %GetJobRequest{job_id: "job-1"},
        response: GetJobResponse
      },
      %{
        service: :job,
        command: :ListJobs,
        server: JobServer,
        function: :list_jobs,
        request: %ListJobsRequest{},
        response: ListJobsResponse
      },
      %{
        service: :job,
        command: :CancelJob,
        server: JobServer,
        function: :cancel_job,
        request: %CancelJobRequest{job_id: "job-1"},
        response: CancelJobResponse
      },
      %{
        service: :job,
        command: :CancelAllJobs,
        server: JobServer,
        function: :cancel_all_jobs,
        request: %CancelAllJobsRequest{},
        response: CancelAllJobsResponse
      },
      %{
        service: :job,
        command: :PauseJob,
        server: JobServer,
        function: :pause_job,
        request: %PauseJobRequest{job_id: "job-1"},
        response: PauseJobResponse
      },
      %{
        service: :job,
        command: :ResumeJob,
        server: JobServer,
        function: :resume_job,
        request: %ResumeJobRequest{job_id: "job-1"},
        response: ResumeJobResponse
      },
      %{
        service: :job,
        command: :ExportJobBackup,
        server: JobServer,
        function: :export_job_backup,
        request: %ExportJobBackupRequest{job_id: "job-1"},
        response: ExportJobBackupResponse
      },
      %{
        service: :job,
        command: :RestoreJobBackup,
        server: JobServer,
        function: :restore_job_backup,
        request: %RestoreJobBackupRequest{},
        response: RestoreJobBackupResponse
      },
      %{
        service: :job,
        command: :ClearJobs,
        server: JobServer,
        function: :clear_jobs,
        request: %ClearJobsRequest{},
        response: ClearJobsResponse
      },
      %{
        service: :job,
        command: :DeployJob,
        server: JobServer,
        function: :deploy_job,
        request: %Mirrorneuron.Job.V1.DeployJobRequest{},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :UpdateDeployment,
        server: JobServer,
        function: :update_deployment,
        request: %UpdateDeploymentRequest{},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :GetDeployment,
        server: JobServer,
        function: :get_deployment,
        request: %GetDeploymentRequest{id_or_key: "dep"},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :ListDeployments,
        server: JobServer,
        function: :list_deployments,
        request: %ListDeploymentsRequest{},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :PromoteDeployment,
        server: JobServer,
        function: :promote_deployment,
        request: %PromoteDeploymentRequest{id_or_key: "dep"},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :RollbackDeployment,
        server: JobServer,
        function: :rollback_deployment,
        request: %RollbackDeploymentRequest{id_or_key: "dep"},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :PauseDeployment,
        server: JobServer,
        function: :pause_deployment,
        request: %DeploymentActionRequest{id_or_key: "dep"},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :ResumeDeployment,
        server: JobServer,
        function: :resume_deployment,
        request: %DeploymentActionRequest{id_or_key: "dep"},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :FailDeployment,
        server: JobServer,
        function: :fail_deployment,
        request: %DeploymentActionRequest{id_or_key: "dep"},
        response: DeploymentResponse
      },
      %{
        service: :job,
        command: :CreateSchedule,
        server: JobServer,
        function: :create_schedule,
        request: %CreateScheduleRequest{},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :UpdateSchedule,
        server: JobServer,
        function: :update_schedule,
        request: %ScheduleActionRequest{schedule_id: "sched"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :GetSchedule,
        server: JobServer,
        function: :get_schedule,
        request: %GetScheduleRequest{schedule_id: "sched"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :ListSchedules,
        server: JobServer,
        function: :list_schedules,
        request: %ListSchedulesRequest{},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :PauseSchedule,
        server: JobServer,
        function: :pause_schedule,
        request: %ScheduleActionRequest{schedule_id: "sched"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :ResumeSchedule,
        server: JobServer,
        function: :resume_schedule,
        request: %ScheduleActionRequest{schedule_id: "sched"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :DeleteSchedule,
        server: JobServer,
        function: :delete_schedule,
        request: %ScheduleActionRequest{schedule_id: "sched"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :DispatchSchedule,
        server: JobServer,
        function: :dispatch_schedule,
        request: %DispatchScheduleRequest{schedule_id: "sched"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :EmitTriggerEvent,
        server: JobServer,
        function: :emit_trigger_event,
        request: %EmitTriggerEventRequest{event_type: "event"},
        response: ScheduleResponse
      },
      %{
        service: :job,
        command: :ListTriggerEvents,
        server: JobServer,
        function: :list_trigger_events,
        request: %ListTriggerEventsRequest{},
        response: ScheduleResponse
      },
      %{
        service: :cluster,
        command: :NetworkHandshake,
        server: ClusterServer,
        function: :network_handshake,
        request: %NetworkHandshakeRequest{},
        response: NetworkHandshakeResponse
      },
      %{
        service: :cluster,
        command: :GetSystemSummary,
        server: ClusterServer,
        function: :get_system_summary,
        request: %GetSystemSummaryRequest{},
        response: GetSystemSummaryResponse
      },
      %{
        service: :cluster,
        command: :GetResource,
        server: ClusterServer,
        function: :get_resource,
        request: %GetResourceRequest{},
        response: GetResourceResponse
      },
      %{
        service: :cluster,
        command: :SetResource,
        server: ClusterServer,
        function: :set_resource,
        request: %SetResourceRequest{},
        response: SetResourceResponse
      },
      %{
        service: :cluster,
        command: :GetRuntimeStatuses,
        server: ClusterServer,
        function: :get_runtime_statuses,
        request: %GetResourceRequest{},
        response: GetResourceResponse
      },
      %{
        service: :cluster,
        command: :PublishRuntimeStatus,
        server: ClusterServer,
        function: :publish_runtime_status,
        request: %SetResourceRequest{},
        response: SetResourceResponse
      },
      %{
        service: :cluster,
        command: :AckRuntimeStatusEvents,
        server: ClusterServer,
        function: :ack_runtime_status_events,
        request: %SetResourceRequest{},
        response: SetResourceResponse
      },
      %{
        service: :cluster,
        command: :SyncLiteLLMGateway,
        server: ClusterServer,
        function: :sync_lite_llm_gateway,
        request: %SetResourceRequest{},
        response: SetResourceResponse
      },
      %{
        service: :cluster,
        command: :RemoveLiteLLMGatewayRoute,
        server: ClusterServer,
        function: :remove_lite_llm_gateway_route,
        request: %SetResourceRequest{},
        response: SetResourceResponse
      },
      %{
        service: :cluster,
        command: :PrepareRuntimeModel,
        server: ClusterServer,
        function: :prepare_runtime_model,
        request: %SetResourceRequest{},
        response: SetResourceResponse
      },
      %{
        service: :cluster,
        command: :PrepareDockerWorker,
        server: ClusterServer,
        function: :prepare_docker_worker,
        request: %PrepareDockerWorkerRequest{},
        response: PrepareDockerWorkerResponse
      },
      %{
        service: :cluster,
        command: :CleanupDockerWorker,
        server: ClusterServer,
        function: :cleanup_docker_worker,
        request: %CleanupDockerWorkerRequest{},
        response: CleanupDockerWorkerResponse
      },
      %{
        service: :cluster,
        command: :AddNode,
        server: ClusterServer,
        function: :add_node,
        request: %AddNodeRequest{node_name: "node@lab"},
        response: AddNodeResponse
      },
      %{
        service: :cluster,
        command: :RemoveNode,
        server: ClusterServer,
        function: :remove_node,
        request: %RemoveNodeRequest{node_name: "node@lab"},
        response: RemoveNodeResponse
      },
      %{
        service: :cluster,
        command: :ReconcileNode,
        server: ClusterServer,
        function: :reconcile_node,
        request: %ReconcileNodeRequest{node_name: "node@lab"},
        response: ReconcileNodeResponse
      },
      %{
        service: :cluster,
        command: :DrainNode,
        server: ClusterServer,
        function: :drain_node,
        request: %DrainNodeRequest{node_name: "node@lab"},
        response: DrainNodeResponse
      },
      %{
        service: :cluster,
        command: :CancelNodeDrain,
        server: ClusterServer,
        function: :cancel_node_drain,
        request: %CancelNodeDrainRequest{node_name: "node@lab"},
        response: CancelNodeDrainResponse
      },
      %{
        service: :cluster,
        command: :SetNodeMaintenance,
        server: ClusterServer,
        function: :set_node_maintenance,
        request: %SetNodeMaintenanceRequest{node_name: "node@lab"},
        response: SetNodeMaintenanceResponse
      },
      %{
        service: :cluster,
        command: :GetNodeDrainStatus,
        server: ClusterServer,
        function: :get_node_drain_status,
        request: %GetNodeDrainStatusRequest{node_name: "node@lab"},
        response: GetNodeDrainStatusResponse
      },
      %{
        service: :cluster,
        command: :ListServices,
        server: ClusterServer,
        function: :list_services,
        request: %ListServicesRequest{},
        response: ListServicesResponse
      },
      %{
        service: :cluster,
        command: :ResolveService,
        server: ClusterServer,
        function: :resolve_service,
        request: %ResolveServiceRequest{name: "svc"},
        response: ResolveServiceResponse
      },
      %{
        service: :cluster,
        command: :CheckServices,
        server: ClusterServer,
        function: :check_services,
        request: %CheckServicesRequest{},
        response: CheckServicesResponse
      },
      %{
        service: :observability,
        command: :StreamEvents,
        server: ObservabilityServer,
        function: :stream_events,
        request: %StreamEventsRequest{job_id: "job-1"},
        response: :streamed
      }
    ]
  end

  defp authenticated_stream do
    %AuthenticatedStream{headers: %{"authorization" => "Bearer #{@identity_token}"}}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
