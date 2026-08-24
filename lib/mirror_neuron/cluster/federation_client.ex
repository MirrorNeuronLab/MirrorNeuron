defmodule MirrorNeuron.Cluster.FederationClient do
  @moduledoc false

  alias MirrorNeuron.Cluster.FederationRegistry
  alias MirrorNeuron.Cluster.NodeAdapter
  alias Mirrorneuron.Cluster.V1.ListServicesRequest
  alias Mirrorneuron.Cluster.V1.ClusterService.Stub, as: ClusterStub
  alias Mirrorneuron.Job.V1.{JobRequest, ListJobsRequest, RunRequest}
  alias Mirrorneuron.Job.V1.JobService.Stub, as: JobStub

  @timeout 15_000

  def call(node_name, function, request) when is_atom(function) do
    response = rpc_call(node_name, JobStub, function, request)
    record_response(node_name, function, response)
    response
  end

  @doc false
  def call_cluster(node_name, function, request) when is_atom(function) do
    rpc_call(node_name, ClusterStub, function, request)
  end

  @doc false
  def discover_job_owner(job_id, options \\ [])

  def discover_job_owner(job_id, options) when is_binary(job_id) do
    discover_owner(job_id, :get_job, :job_id, options)
  end

  def discover_job_owner(_job_id, _options), do: nil

  @doc false
  def discover_run_owner(run_id, options \\ [])

  def discover_run_owner(run_id, options) when is_binary(run_id) do
    discover_owner(run_id, :get_run, :run_id, options)
  end

  def discover_run_owner(_run_id, _options), do: nil

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

  defp discover_owner(resource_id, function, field, options) do
    peers = Keyword.get(options, :peers, FederationRegistry.list())
    invoke = Keyword.get(options, :call, &call/3)

    Enum.reduce_while(peers, nil, fn peer, _owner ->
      node_name = Map.get(peer, "node_name")

      if is_binary(node_name) and String.trim(node_name) != "" do
        try do
          _response = invoke.(node_name, function, discovery_request(field, resource_id))
          {:halt, node_name}
        rescue
          error in GRPC.RPCError ->
            if error.status == GRPC.Status.not_found() or availability_failure?(error) do
              {:cont, nil}
            else
              reraise error, __STACKTRACE__
            end
        end
      else
        {:cont, nil}
      end
    end)
  end

  defp discovery_request(:job_id, job_id), do: %JobRequest{job_id: job_id, version: 1}
  defp discovery_request(:run_id, run_id), do: %RunRequest{run_id: run_id, version: 1}

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
    _ = replay_archive_tombstones(node_name)
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

  @doc false
  def replay_archive_tombstones(node_name, options \\ [])

  def replay_archive_tombstones(node_name, options) when is_binary(node_name) do
    registry = Keyword.get(options, :federation_registry, FederationRegistry)
    invoke = Keyword.get(options, :call, &call/3)

    with {:ok, tombstones} <- registry.archive_tombstones(node_name) do
      outcomes =
        Enum.map(tombstones, fn tombstone ->
          replay_archive_tombstone(node_name, tombstone, registry, invoke)
        end)

      {:ok, outcomes}
    end
  end

  def replay_archive_tombstones(_node_name, _options), do: {:error, :invalid_owner_node}

  defp replay_archive_tombstone(node_name, tombstone, registry, invoke) do
    job_id = Map.get(tombstone, "job_id")
    expected_revision = Map.get(tombstone, "expected_revision", 0)

    if is_binary(job_id) and is_integer(expected_revision) and expected_revision >= 0 do
      request = %JobRequest{
        job_id: job_id,
        expected_revision: expected_revision,
        version: 1
      }

      try do
        _response = invoke.(node_name, :archive_job, request)
        :ok = registry.clear_archive_tombstone(node_name, job_id)
        %{job_id: job_id, status: :applied}
      rescue
        error in GRPC.RPCError ->
          if availability_failure?(error) do
            %{job_id: job_id, status: :pending}
          else
            :ok = registry.clear_archive_tombstone(node_name, job_id)
            %{job_id: job_id, status: :rejected}
          end
      end
    else
      %{job_id: job_id, status: :invalid}
    end
  end

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
