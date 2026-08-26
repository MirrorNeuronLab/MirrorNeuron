defmodule MirrorNeuron.Grpc.CommandHubTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.{CommandHub, CommandPolicy, Endpoint, JobServer}

  alias Mirrorneuron.Job.V1.{
    CreateJobRequest,
    CreateJobScheduleRequest,
    DeleteJobRequest,
    DeleteRunRequest,
    GetJobResponseTurnRequest,
    JobRequest,
    JsonResponse,
    ListJobsRequest,
    QueryJobResponseRequest,
    RunRequest,
    SendRunInputRequest,
    StartRunRequest,
    UpdateJobRequest
  }

  @identity_token "command-hub-identity"
  @test_pid_name :grpc_command_hub_test_pid

  @rpc_cases [
    {:CreateJob, :create_job, CreateJobRequest},
    {:GetJob, :get_job, JobRequest},
    {:ListJobs, :list_jobs, ListJobsRequest},
    {:UpdateJob, :update_job, UpdateJobRequest},
    {:ArchiveJob, :archive_job, JobRequest},
    {:ResetJobData, :reset_job_data, JobRequest},
    {:DeleteJob, :delete_job, DeleteJobRequest},
    {:StartRun, :start_run, StartRunRequest},
    {:ListRuns, :list_runs, JobRequest},
    {:GetRun, :get_run, RunRequest},
    {:PauseRun, :pause_run, RunRequest},
    {:ResumeRun, :resume_run, RunRequest},
    {:CancelRun, :cancel_run, RunRequest},
    {:DeleteRun, :delete_run, DeleteRunRequest},
    {:SendRunInput, :send_run_input, SendRunInputRequest},
    {:CreateJobSchedule, :create_job_schedule, CreateJobScheduleRequest},
    {:QueryJobResponse, :query_job_response, QueryJobResponseRequest},
    {:GetJobResponseTurn, :get_job_response_turn, GetJobResponseTurnRequest}
  ]

  @identity_commands @rpc_cases |> Enum.map(&elem(&1, 0)) |> MapSet.new()

  defmodule AuthenticatedStream do
    defstruct headers: %{}
  end

  defmodule FakeJobCommands do
    @test_pid_name :grpc_command_hub_test_pid

    for function <- [
          :create_job,
          :get_job,
          :list_jobs,
          :update_job,
          :archive_job,
          :reset_job_data,
          :delete_job,
          :start_run,
          :list_runs,
          :get_run,
          :pause_run,
          :resume_run,
          :cancel_run,
          :delete_run,
          :send_run_input,
          :create_job_schedule,
          :query_job_response,
          :get_job_response_turn
        ] do
      def unquote(function)(request, stream) do
        if pid = Process.whereis(@test_pid_name),
          do: send(pid, {:called, unquote(function), request, stream})

        %JsonResponse{result_json: "{}", version: 1}
      end
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)

    previous_dependencies = Application.get_env(:mirror_neuron, :grpc_command_dependencies)
    previous_network_only = Application.get_env(:mirror_neuron, :network_only)
    previous_network_only_env = System.get_env("MN_NETWORK_ONLY")
    previous_auth_token = System.get_env("MN_GRPC_AUTH_TOKEN")

    Application.put_env(:mirror_neuron, :grpc_command_dependencies, %{job: FakeJobCommands})
    Application.put_env(:mirror_neuron, :network_only, false)
    System.delete_env("MN_NETWORK_ONLY")
    System.put_env("MN_GRPC_AUTH_TOKEN", @identity_token)

    on_exit(fn ->
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      restore_app_env(:grpc_command_dependencies, previous_dependencies)
      restore_app_env(:network_only, previous_network_only)
      restore_system_env("MN_NETWORK_ONLY", previous_network_only_env)
      restore_system_env("MN_GRPC_AUTH_TOKEN", previous_auth_token)
    end)

    :ok
  end

  test "generated v1 service and endpoint expose exactly the durable job/run contract" do
    assert Mirrorneuron.Job.V1.JobService.Service.__meta__(:name) ==
             "mirrorneuron.job.v1.JobService"

    assert Enum.map(Mirrorneuron.Job.V1.JobService.Service.__rpc_calls__(), &elem(&1, 0)) ==
             Enum.map(@rpc_cases, &elem(&1, 0))

    assert Endpoint.__meta__(:servers) |> Enum.sort() ==
             [
               JobServer,
               MirrorNeuron.Grpc.ClusterServer,
               MirrorNeuron.Grpc.ObservabilityServer,
               MirrorNeuron.Grpc.OperationsServer
             ]
             |> Enum.sort()

    refute Code.ensure_loaded?(Mirrorneuron.Job.V2.JobService.Service)
    refute Code.ensure_loaded?(MirrorNeuron.Grpc.JobV2Server)
  end

  test "server adapters route every job RPC through the single job namespace" do
    stream = authenticated_stream()

    for {_command, function, request_module} <- @rpc_cases do
      request = struct(request_module, version: 1)
      assert %JsonResponse{version: 1} = apply(JobServer, function, [request, stream])
      assert_receive {:called, ^function, ^request, ^stream}
    end
  end

  test "default command registry contains one handler for all and only v1 job RPCs" do
    Application.delete_env(:mirror_neuron, :grpc_command_dependencies)

    job_entries =
      CommandHub.default_modules()
      |> Enum.filter(fn {{service, _command}, _module} -> service == :job end)
      |> Map.new()

    assert Map.keys(job_entries) |> Enum.sort() ==
             Enum.map(@rpc_cases, fn {command, _function, _request} -> {:job, command} end)
             |> Enum.sort()

    assert Enum.all?(job_entries, fn {_key, module} ->
             module == MirrorNeuron.Grpc.Handlers.Job
           end)
  end

  test "job policies preserve network-only and identity requirements" do
    for {command, _function, _request} <- @rpc_cases do
      assert CommandPolicy.policies(:job, command) == %{
               network_only_denied: true,
               identity_auth_required: MapSet.member?(@identity_commands, command),
               network_join_auth_required: false
             }
    end

    refute CommandPolicy.network_only_denied?(:job_v2, :CreateJob)
  end

  test "network-only policy rejects v1 job commands before handler dispatch" do
    Application.put_env(:mirror_neuron, :network_only, true)

    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.create_job(%CreateJobRequest{version: 1}, authenticated_stream())
      end

    assert Exception.message(error) == "CreateJob is disabled while MN_NETWORK_ONLY=true"
    refute_received {:called, :create_job, _, _}
  end

  test "all v1 commands require the configured client identity" do
    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.cancel_run(%RunRequest{run_id: "run-1", version: 1}, nil)
      end

    assert Exception.message(error) == "gRPC client identity is required for this RPC"

    assert %JsonResponse{version: 1} =
             JobServer.cancel_run(
               %RunRequest{run_id: "run-1", version: 1},
               authenticated_stream()
             )

    assert_raise GRPC.RPCError, fn ->
      JobServer.get_job(%JobRequest{job_id: "job-1", version: 1}, nil)
    end
  end

  test "version-zero requests are rejected before command dispatch" do
    error =
      assert_raise GRPC.RPCError, fn ->
        JobServer.get_job(%JobRequest{job_id: "job-1"}, authenticated_stream())
      end

    assert error.status == GRPC.Status.invalid_argument()

    assert Exception.message(error) ==
             "unsupported MirrorNeuron interface version 0; expected 1"

    refute_received {:called, :get_job, _, _}
  end

  defp authenticated_stream do
    %AuthenticatedStream{headers: %{"authorization" => "Bearer #{@identity_token}"}}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
