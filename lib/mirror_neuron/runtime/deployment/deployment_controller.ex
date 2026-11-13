defmodule MirrorNeuron.Runtime.DeploymentController do
  @moduledoc "Deployment lifecycle, promotion and rollback entrypoints."

  alias MirrorNeuron.Runtime.DeploymentController.Operations

  defdelegate deploy_manifest(input), to: Operations
  defdelegate deploy_manifest(input, opts), to: Operations
  defdelegate update_deployment(deployment_key, input), to: Operations
  defdelegate update_deployment(deployment_key, input, opts), to: Operations
  defdelegate promote_deployment(id_or_key), to: Operations
  defdelegate promote_deployment(id_or_key, opts), to: Operations
  defdelegate rollback_deployment(id_or_key), to: Operations
  defdelegate rollback_deployment(id_or_key, opts), to: Operations
  defdelegate pause_deployment(id_or_key), to: Operations
  defdelegate pause_deployment(id_or_key, opts), to: Operations
  defdelegate resume_deployment(id_or_key), to: Operations
  defdelegate resume_deployment(id_or_key, opts), to: Operations
  defdelegate fail_deployment(id_or_key), to: Operations
  defdelegate fail_deployment(id_or_key, opts), to: Operations
  defdelegate get_deployment(id_or_key), to: Operations
  defdelegate list_deployments(), to: Operations
  defdelegate list_deployments(opts), to: Operations
end
