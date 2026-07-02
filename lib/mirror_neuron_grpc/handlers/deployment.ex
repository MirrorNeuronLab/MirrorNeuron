defmodule MirrorNeuron.Grpc.Handlers.Deployment do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Grpc.Handlers.Support
  alias Mirrorneuron.Job.V1.DeploymentResponse

  def deploy_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DeployJob")

    with {:ok, tmp_dir} <- Support.request_bundle_dir(request.manifest_json, request.payloads),
         {:ok, result} <-
           MirrorNeuron.deploy_manifest(tmp_dir,
             deployment_key: Support.blank_to_nil(request.deployment_key),
             update_policy: Support.decode_json_map(request.update_policy_json),
             wait: request.wait
           ) do
      %DeploymentResponse{
        result_json: Support.versioned_json(result),
        version: @interface_version
      }
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def update_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("UpdateDeployment")

    with {:ok, tmp_dir} <- Support.request_bundle_dir(request.manifest_json, request.payloads),
         {:ok, result} <-
           MirrorNeuron.update_deployment(request.deployment_key, tmp_dir,
             update_policy: Support.decode_json_map(request.update_policy_json),
             wait: request.wait
           ) do
      %DeploymentResponse{
        result_json: Support.versioned_json(result),
        version: @interface_version
      }
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def get_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetDeployment")

    case MirrorNeuron.get_deployment(request.id_or_key) do
      {:ok, result} ->
        %DeploymentResponse{
          result_json: Support.versioned_json(result),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: :not_found, message: inspect(reason)
    end
  end

  def list_deployments(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListDeployments")

    opts =
      request.query_json
      |> Support.decode_json_map()
      |> keyword_opts()

    case MirrorNeuron.list_deployments(opts) do
      {:ok, result} ->
        %DeploymentResponse{
          result_json: Support.versioned_json(%{"data" => result}),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  def promote_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PromoteDeployment")
    deployment_action_response(MirrorNeuron.promote_deployment(request.id_or_key))
  end

  def rollback_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RollbackDeployment")

    opts =
      []
      |> Support.maybe_put_opt(:version, request.version)
      |> Support.maybe_put_opt(:tag, request.tag)
      |> Support.maybe_put_opt(:reason, request.reason)

    deployment_action_response(MirrorNeuron.rollback_deployment(request.id_or_key, opts))
  end

  def pause_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PauseDeployment")

    deployment_action_response(
      MirrorNeuron.pause_deployment(request.id_or_key, reason: request.reason)
    )
  end

  def resume_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResumeDeployment")

    deployment_action_response(
      MirrorNeuron.resume_deployment(request.id_or_key, reason: request.reason)
    )
  end

  def fail_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("FailDeployment")

    deployment_action_response(
      MirrorNeuron.fail_deployment(request.id_or_key, reason: request.reason)
    )
  end

  defp deployment_action_response({:ok, result}) do
    %DeploymentResponse{result_json: Support.versioned_json(result), version: @interface_version}
  end

  defp deployment_action_response({:error, reason}) do
    raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
  end

  defp keyword_opts(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {"deployment_key", value} -> [deployment_key: value]
      {"status", value} -> [status: value]
      _other -> []
    end)
  end
end
