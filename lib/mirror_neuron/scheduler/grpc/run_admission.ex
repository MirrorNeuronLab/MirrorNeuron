defmodule MirrorNeuron.Grpc.Handlers.RunAdmission do
  @moduledoc "Validates local Run ownership and peer admission capability."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Cluster.FederationClient
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Handlers.Support

  def check_run_admission(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil ->
        with {:ok, definition} <- MirrorNeuron.Runtime.StableJob.get(request.job_id),
             true <- definition["status"] == "active",
             {:ok, manifest} <- admission_manifest(definition, request.run_id),
             {:ok, check} <-
               MirrorNeuron.Runtime.NodeAdmission.check(
                 manifest,
                 Support.blank_to_nil(request.run_id)
               ) do
          Encoding.response(check)
        else
          false -> Encoding.respond({:error, :job_not_active})
          error -> Encoding.respond(error)
        end

      owner ->
        Remote.forward_call(owner, :check_run_admission, request, stream)
    end
  end

  defp admission_manifest(definition, ""), do: {:ok, definition["manifest"]}

  defp admission_manifest(definition, run_id) do
    with {:ok, run} <- MirrorNeuron.Persistence.RedisStore.fetch_job(run_id),
         true <- run["stable_job_id"] == definition["job_id"] do
      {:ok, run["manifest"]}
    else
      _ -> {:error, :not_found}
    end
  end

  def ensure_peer_admission!(owner) do
    response =
      FederationClient.call_cluster(
        owner,
        :get_resource,
        %Mirrorneuron.Cluster.V1.GetResourceRequest{version: 1}
      )

    report = Support.decode_json_map(response.resource_json)

    supported =
      Enum.any?(report["nodes"] || [], fn node ->
        node["name"] == owner and
          get_in(node, ["admission", "capability"]) == "resource_admission_v2"
      end)

    unless supported do
      raise GRPC.RPCError,
        status: GRPC.Status.failed_precondition(),
        message:
          "The selected PC does not advertise resource_admission_v2. Update its runtime before starting protected work."
    end
  end
end
