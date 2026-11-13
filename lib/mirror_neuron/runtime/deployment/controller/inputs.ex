defmodule MirrorNeuron.Runtime.DeploymentController.Inputs do
  @moduledoc "Deployment-specific bundle options and executable input preflight."

  alias MirrorNeuron.JobBundle

  def apply_deployment_options(%JobBundle{manifest: manifest} = bundle, opts) do
    deployment_key = Keyword.get(opts, :deployment_key)
    update_policy = Keyword.get(opts, :update_policy, %{})

    deployment =
      (manifest.deployment || %{})
      |> maybe_put_deployment_key(deployment_key)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    policies =
      manifest.policies || %{}

    policies =
      if map_size(update_policy) > 0 do
        Map.put(policies, "update", Map.merge(Map.get(policies, "update", %{}), update_policy))
      else
        policies
      end

    {:ok, %{bundle | manifest: %{manifest | deployment: deployment, policies: policies}}}
  end

  def preflight_bundle(bundle) do
    with :ok <- MirrorNeuron.ServicePreflight.run(bundle),
         :ok <- MirrorNeuron.BlueprintValidation.run_input_validation(bundle),
         :ok <- MirrorNeuron.BlueprintValidation.check_requirements(bundle.manifest) do
      :ok
    end
  end

  defp maybe_put_deployment_key(deployment, nil), do: deployment

  defp maybe_put_deployment_key(deployment, ""), do: deployment

  defp maybe_put_deployment_key(deployment, key), do: Map.put(deployment, "key", key)
end
