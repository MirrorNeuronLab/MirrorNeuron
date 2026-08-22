defmodule MirrorNeuron.Cluster.FederationClient do
  @moduledoc false

  alias MirrorNeuron.Cluster.FederationRegistry
  alias MirrorNeuron.Cluster.NodeAdapter
  alias Mirrorneuron.Cluster.V1.ListServicesRequest
  alias Mirrorneuron.Cluster.V1.ClusterService.Stub, as: ClusterStub
  alias Mirrorneuron.Job.V1.{JobRequest, ListJobsRequest}
  alias Mirrorneuron.Job.V1.JobService.Stub, as: JobStub

  @timeout 15_000

  def call(node_name, function, request) when is_atom(function) do
    response = rpc_call(node_name, JobStub, function, request)
    record_response(node_name, function, response)
    response
  end

  def list_services(node_name, opts \\ []) when is_list(opts) do
    request = %ListServicesRequest{
      query_json: opts |> Map.new() |> Jason.encode!(),
      version: 1
    }

    node_name
    |> rpc_call(ClusterStub, :list_services, request)
    |> Map.get(:result_json)
    |> decode_services()
  end

  @doc false
  def decode_services(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"services" => services}} when is_list(services) -> services
      _ -> []
    end
  end

  def decode_services(_json), do: []

  defp rpc_call(node_name, stub, function, request) do
    with {:ok, peer} <- FederationRegistry.fetch(node_name),
         {:ok, target} <- target(peer),
         {:ok, channel} <- connect(target, peer),
         result <- apply(stub, function, [channel, request, [timeout: @timeout]]) do
      _ = GRPC.Stub.disconnect(channel)

      case result do
        {:ok, response} ->
          response

        {:error, reason} ->
          if availability_failure?(reason) do
            unavailable!(node_name, reason)
          else
            raise reason
          end
      end
    else
      {:error, reason} -> unavailable!(node_name, reason)
    end
  end

  def sync_peer(node_name) do
    response =
      call(
        node_name,
        :list_jobs,
        %ListJobsRequest{include_archived: true, page_size: 1_000, local_only: true, version: 1}
      )

    jobs = response.result_json |> decode_items()
    _ = FederationRegistry.replace_projections(node_name, jobs)

    runs =
      Enum.flat_map(jobs, fn job ->
        case Map.get(job, "job_id") do
          job_id when is_binary(job_id) and job_id != "" ->
            try do
              call(node_name, :list_runs, %JobRequest{
                job_id: job_id,
                page_size: 1_000,
                version: 1
              })
              |> Map.get(:result_json)
              |> decode_items()
            rescue
              _ -> []
            end

          _ ->
            []
        end
      end)

    _ = FederationRegistry.replace_run_projections(node_name, runs)
    {:ok, %{jobs: length(jobs), runs: length(runs)}}
  rescue
    error ->
      _ = FederationRegistry.mark_unavailable(node_name)
      {:error, error}
  end

  @doc false
  def availability_failure?(%GRPC.RPCError{status: status}) do
    status in [
      GRPC.Status.deadline_exceeded(),
      GRPC.Status.unauthenticated(),
      GRPC.Status.unavailable()
    ]
  end

  def availability_failure?(_reason), do: true

  defp connect(target, peer) do
    token = Map.get(peer, "peer_auth_token", "")

    GRPC.Stub.connect(target,
      timeout: @timeout,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"x-mn-federation-peer", to_string(NodeAdapter.self())},
        {"x-mn-federation-hop", "1"}
      ]
    )
  end

  defp target(peer) do
    host = to_string(Map.get(peer, "grpc_host") || "") |> String.trim()
    port = Map.get(peer, "grpc_port")

    if host == "" or port in [nil, "", 0],
      do: {:error, :peer_endpoint_unavailable},
      else: {:ok, "#{host}:#{port}"}
  end

  defp record_response(node_name, function, %{result_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"status" => "deleted", "job_id" => job_id}} when function == :delete_job ->
        FederationRegistry.remove_projection(node_name, job_id)

      {:ok, %{"status" => "deleted", "run_id" => run_id}} when function == :delete_run ->
        FederationRegistry.remove_projection(node_name, run_id)

      {:ok, %{"items" => items}} when is_list(items) ->
        if Enum.all?(items, &(is_map(&1) and Map.has_key?(&1, "run_id"))) do
          FederationRegistry.put_run_projections(node_name, items)
        else
          FederationRegistry.put_projection(node_name, items)
        end

      {:ok, %{"run_id" => _} = run} ->
        FederationRegistry.put_run_projections(node_name, [run])

      {:ok, %{"job_id" => _} = job} ->
        FederationRegistry.put_projection(node_name, [job])

      _ ->
        :ok
    end
  end

  defp record_response(_node_name, _function, _response), do: :ok

  defp decode_items(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"items" => items}} when is_list(items) -> items
      _ -> []
    end
  end

  defp unavailable!(node_name, reason) do
    _ = FederationRegistry.mark_unavailable(node_name)

    raise GRPC.RPCError,
      status: GRPC.Status.unavailable(),
      message: "MN_NODE_UNAVAILABLE: owner #{node_name} is unreachable (#{safe_reason(reason)})"
  end

  defp safe_reason(%GRPC.RPCError{status: status}), do: "grpc_status_#{status}"
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "peer_call_failed"
end
