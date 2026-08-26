defmodule MirrorNeuron.Cluster.FederationClientTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.FederationClient
  alias Mirrorneuron.Job.V1.{JobRequest, RunRequest}

  test "uses a bounded extended timeout only for semantic Job responses" do
    assert FederationClient.request_timeout(:query_job_response) == 60_000
    assert FederationClient.request_timeout(:delete_job) == 300_000
    assert FederationClient.request_timeout(:delete_run) == 300_000
    assert FederationClient.request_timeout(:get_job_response_turn) == 15_000
    assert FederationClient.request_timeout(:get_job) == 15_000
  end

  test "discovers connected job and run owners without a cached projection" do
    peers = [
      %{"node_name" => "mirror_neuron@offline"},
      %{"node_name" => "mirror_neuron@spark"}
    ]

    not_found = GRPC.RPCError.exception(status: GRPC.Status.not_found(), message: "not found")

    unavailable =
      GRPC.RPCError.exception(status: GRPC.Status.unavailable(), message: "peer unavailable")

    job_call = fn
      "mirror_neuron@offline", :get_job, %JobRequest{job_id: "job-remote"} -> raise unavailable
      "mirror_neuron@spark", :get_job, %JobRequest{job_id: "job-remote"} -> :found
    end

    run_call = fn
      "mirror_neuron@offline", :get_run, %RunRequest{run_id: "run-remote"} -> raise not_found
      "mirror_neuron@spark", :get_run, %RunRequest{run_id: "run-remote"} -> :found
    end

    assert FederationClient.discover_job_owner("job-remote", peers: peers, call: job_call) ==
             "mirror_neuron@spark"

    assert FederationClient.discover_run_owner("run-remote", peers: peers, call: run_call) ==
             "mirror_neuron@spark"
  end

  test "application errors do not mark a federated peer unavailable" do
    refute FederationClient.availability_failure?(
             GRPC.RPCError.exception(
               status: GRPC.Status.internal(),
               message: "not_found"
             )
           )

    refute FederationClient.availability_failure?(
             GRPC.RPCError.exception(
               status: GRPC.Status.failed_precondition(),
               message: "invalid state"
             )
           )
  end

  test "transport and authentication failures mark a federated peer unavailable" do
    for status <- [
          GRPC.Status.deadline_exceeded(),
          GRPC.Status.unauthenticated(),
          GRPC.Status.unavailable()
        ] do
      assert FederationClient.availability_failure?(
               GRPC.RPCError.exception(status: status, message: "peer unavailable")
             )
    end

    assert FederationClient.availability_failure?(:econnrefused)
  end

  test "decodes federated service-list responses" do
    assert FederationClient.decode_services(
             Jason.encode!(%{
               "services" => [
                 %{"id" => "service-1", "job_id" => "job-1", "status" => "passing"}
               ],
               "version" => 1
             })
           ) == [%{"id" => "service-1", "job_id" => "job-1", "status" => "passing"}]

    assert FederationClient.decode_services("{}") == []
    assert FederationClient.decode_services("not-json") == []
  end
end
