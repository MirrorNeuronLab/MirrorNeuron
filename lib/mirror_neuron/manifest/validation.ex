defmodule MirrorNeuron.Manifest.Validation do
  @moduledoc "Composes independent executable manifest validation boundaries."

  alias MirrorNeuron.Manifest.Completion
  alias MirrorNeuron.Runtime.DeploymentPolicy
  alias MirrorNeuron.Runtime.LifecyclePolicy
  alias MirrorNeuron.Scheduler.ManifestPolicy
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Manifest.ResponseService
  alias MirrorNeuron.Runner.Policy, as: RunnerPolicy
  alias MirrorNeuron.ServiceSpec
  alias MirrorNeuron.Manifest.Topology
  alias MirrorNeuron.Manifest.Values
  alias MirrorNeuron.Manifest.WorkflowGraph

  @api_version "mn.workflow/v1"

  def validate(%MirrorNeuron.Manifest{} = manifest) do
    errors =
      []
      |> validate_required(manifest)
      |> Topology.validate_nodes(manifest)
      |> Topology.validate_edges(manifest)
      |> WorkflowGraph.validate_workflow_flow(manifest)
      |> Topology.validate_entrypoints(manifest)
      |> validate_type(manifest)
      |> validate_required_context_engine(manifest)
      |> validate_requirements(manifest)
      |> validate_input_validation(manifest)
      |> validate_services(manifest)
      |> validate_deployment(manifest)
      |> ManifestPolicy.validate_schedule(manifest)
      |> ResponseService.validate_response_service(manifest)
      |> Completion.validate_completion_contract(manifest)
      |> validate_policies(manifest)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_required(errors, manifest) do
    errors
    |> Values.maybe_add_error(
      manifest.api_version != @api_version,
      "apiVersion must be #{@api_version}"
    )
    |> Values.maybe_add_error(manifest.kind != "Workflow", "kind must be Workflow")
    |> Values.maybe_add_error(is_nil(manifest.manifest_version), "manifest_version is required")
    |> Values.maybe_add_error(
      not Values.nonempty_string?(manifest.graph_id),
      "graph_id must be a non-empty string"
    )
    |> Values.maybe_add_error(
      not Values.nonempty_string?(manifest.job_name),
      "job_name must be a non-empty string"
    )
    |> Values.maybe_add_error(manifest.nodes == [], "nodes must not be empty")
  end

  defp validate_policies(errors, manifest) do
    supported_recovery_modes = Application.get_env(:mirror_neuron, :supported_recovery_modes, [])
    policies = manifest.policies
    recovery_mode = if is_map(policies), do: Map.get(policies, "recovery_mode", "auto")

    errors
    |> Values.maybe_add_error(not is_map(policies), "policies must be an object")
    |> Values.maybe_add_error(
      is_map(policies) and recovery_mode not in supported_recovery_modes,
      "unsupported recovery_mode #{inspect(recovery_mode)}"
    )
    |> ManifestPolicy.validate_scheduler_policy(manifest)
    |> ManifestPolicy.validate_node_scheduling(manifest)
    |> Values.add_errors(ResourceSpec.validate_manifest(manifest))
    |> Values.add_errors(RunnerPolicy.validate_manifest(manifest))
    |> Values.add_errors(LifecyclePolicy.validate_manifest(manifest))
    |> Values.add_errors(MirrorNeuron.Runtime.WorkflowBudget.validation_errors(policies))
  end

  defp validate_type(errors, manifest) do
    Values.maybe_add_error(
      errors,
      manifest.type not in ["batch", "service"],
      "type must be service or omitted for batch"
    )
  end

  defp validate_required_context_engine(errors, manifest) do
    Values.maybe_add_error(
      errors,
      not is_boolean(manifest.required_context_engine),
      "required_context_engine must be a boolean"
    )
  end

  defp validate_requirements(errors, manifest) do
    errors
    |> Values.maybe_add_error(
      not is_map(manifest.requirements),
      "requirements must be an object"
    )
  end

  defp validate_input_validation(errors, manifest) do
    validation = manifest.input_validation

    cond do
      is_nil(validation) ->
        errors

      is_map(validation) ->
        rules = Map.get(validation, "rules", [])

        Values.maybe_add_error(
          errors,
          not is_list(rules),
          "input_validation.rules must be a list"
        )

      is_list(validation) ->
        errors

      true ->
        ["input_validation must be an object or list" | errors]
    end
  end

  defp validate_services(errors, manifest) do
    Values.add_errors(errors, ServiceSpec.validate_manifest(manifest))
  end

  defp validate_deployment(errors, manifest) do
    Values.add_errors(errors, DeploymentPolicy.validate_manifest(manifest))
  end
end
