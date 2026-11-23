defmodule MirrorNeuron.Grpc.RuntimeControlRoute do
  @moduledoc false
  alias MirrorNeuron.Cluster.{FederatedJobRouting, FederationRegistry, NodeAdapter}

  @job_integrations ~w(create_job_backup list_job_skills add_job_skill set_job_skill list_job_integrations
    add_job_slack connect_job_slack control_job_slack deliver_job_slack enabled_job_skill_files)

  # Only Core membership selects physical endpoints and peer credentials.
  # Python owners supply a node identity, never an arbitrary forwarding URL.
  def resolve(request, fetch \\ &FederationRegistry.fetch/1) do
    with {:ok, arguments} when is_map(arguments) <- Jason.decode(request.arguments_json) do
      {owner, arguments} = Map.pop(arguments, "_owner_node")
      {hop, arguments} = Map.pop(arguments, "_runtime_hop", 0)
      local = to_string(NodeAdapter.self())

      owner =
        if request.action in @job_integrations or
             (request.action == "mcp.supervision" and
                arguments["method"] == "enabled_skill_bundles") do
          job_owner(arguments["job_id"], owner, local)
        else
          owner
        end

      cond do
        is_nil(owner) or owner == local ->
          target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET", "") |> String.trim()
          if target == "", do: unavailable!()

          metadata = %{
            "authorization" => "Bearer " <> MirrorNeuron.Grpc.Tokens.runtime_control_token()
          }

          {target, %{request | arguments_json: Jason.encode!(arguments)}, metadata}

        not is_binary(owner) or hop != 0 ->
          raise GRPC.RPCError,
            status: GRPC.Status.failed_precondition(),
            message: "Runtime owner changed during forwarding"

        true ->
          case fetch.(owner) do
            {:ok, %{"grpc_host" => host, "grpc_port" => port, "peer_auth_token" => token}}
            when is_binary(host) and is_integer(port) and port > 0 and port < 65_536 and
                   is_binary(token) and token != "" ->
              target =
                if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"

              arguments = arguments |> Map.put("_owner_node", owner) |> Map.put("_runtime_hop", 1)
              metadata = %{"authorization" => "Bearer " <> token, "x-mn-federation-peer" => local}
              {target, %{request | arguments_json: Jason.encode!(arguments)}, metadata}

            _ ->
              unavailable!()
          end
      end
    else
      _ ->
        raise GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: "Runtime arguments must be an object"
    end
  end

  defp job_owner(job_id, supplied, local) when is_binary(job_id) do
    owner =
      case MirrorNeuron.get_job(job_id) do
        {:ok, definition} -> definition["owner_node"] || local
        _ -> FederatedJobRouting.job_owner(job_id)
      end

    cond do
      is_nil(owner) ->
        raise GRPC.RPCError, status: GRPC.Status.not_found(), message: "Job unavailable"

      supplied && supplied != owner ->
        raise GRPC.RPCError,
          status: GRPC.Status.failed_precondition(),
          message: "Job owner changed"

      true ->
        owner
    end
  end

  defp job_owner(_, _, _),
    do: raise(GRPC.RPCError, status: GRPC.Status.invalid_argument(), message: "Missing job ID")

  defp unavailable! do
    raise GRPC.RPCError,
      status: GRPC.Status.unavailable(),
      message: "The owning runtime endpoint is unavailable"
  end
end
