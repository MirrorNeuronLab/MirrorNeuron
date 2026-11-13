defmodule MirrorNeuron.Grpc.Handlers.Job.Remote do
  @moduledoc "Owner forwarding, single-hop fencing and deferred federation operations."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Cluster.FederatedJobRouting
  alias MirrorNeuron.Cluster.FederationClient
  alias MirrorNeuron.Cluster.FederationRegistry

  @unavailable_status GRPC.Status.unavailable()

  def forward_archive_or_queue(owner, request, stream) do
    try do
      forward_call(owner, :archive_job, request, stream)
    rescue
      error in GRPC.RPCError ->
        if FederationClient.availability_failure?(error) do
          case FederationRegistry.queue_archive_tombstone(
                 owner,
                 request.job_id,
                 request.expected_revision
               ) do
            {:ok, tombstone} ->
              Encoding.response(%{
                "job_id" => request.job_id,
                "owner_node" => owner,
                "status" => "archive_pending",
                "archive_tombstone" => tombstone
              })

            error ->
              Encoding.respond(error)
          end
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  def forward_delete_or_queue(_owner, %{confirmed: false}, _stream),
    do: Encoding.respond({:error, :confirmation_required})

  def forward_delete_or_queue(owner, request, stream) do
    try do
      response = forward_call(owner, :delete_job, request, stream)
      _ = FederationRegistry.clear_delete_tombstone(owner, request.job_id)
      response
    rescue
      error in GRPC.RPCError ->
        if FederationClient.availability_failure?(error) do
          case FederationRegistry.queue_delete_tombstone(
                 owner,
                 request.job_id,
                 request.expected_revision
               ) do
            {:ok, tombstone} ->
              Encoding.response(%{
                "job_id" => request.job_id,
                "owner_node" => owner,
                "status" => "delete_pending",
                "delete_tombstone" => tombstone
              })

            error ->
              Encoding.respond(error)
          end
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  def remote_job_owner(job_id), do: FederatedJobRouting.job_owner(job_id)

  def remote_run_owner(run_id), do: FederatedJobRouting.run_owner(run_id)

  def remote_read(resource_id, owner_lookup, function, request, stream) do
    case owner_lookup.(resource_id) do
      nil ->
        Encoding.respond({:error, :not_found})

      owner ->
        try do
          forward_call(owner, function, request, stream)
        rescue
          error in GRPC.RPCError ->
            if error.status == @unavailable_status do
              case FederationRegistry.projection(resource_id) do
                nil ->
                  reraise error, __STACKTRACE__

                projection ->
                  Encoding.response(projection)
              end
            else
              reraise error, __STACKTRACE__
            end
        end
    end
  end

  def remote_runs_read(owner, request, stream) do
    try do
      forward_call(owner, :list_runs, request, stream)
    rescue
      error in GRPC.RPCError ->
        if error.status == @unavailable_status do
          items =
            FederationRegistry.run_projections()
            |> Enum.filter(&(Map.get(&1, "job_id") == request.job_id))

          Encoding.response(%{
            "job_id" => request.job_id,
            "items" => items,
            "next_page_token" => nil
          })
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  def forward_call(owner, function, request, stream) do
    if MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 do
      raise GRPC.RPCError,
        status: GRPC.Status.failed_precondition(),
        message: "MN_FEDERATION_LOOP: forwarded request cannot be forwarded again"
    end

    FederationClient.call(owner, function, request)
  end
end
