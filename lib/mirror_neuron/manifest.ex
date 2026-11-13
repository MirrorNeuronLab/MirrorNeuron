defmodule MirrorNeuron.Manifest do
  defstruct [
    :api_version,
    :kind,
    :manifest_version,
    :graph_id,
    :job_name,
    :type,
    :contract,
    :flow,
    :runtime,
    :required_context_engine,
    :requirements,
    :skill_dependencies,
    :input_validation,
    :services,
    :required_services,
    :deployment,
    :schedule,
    :triggers,
    :parameterized,
    :response_service,
    :metadata,
    :nodes,
    :edges,
    :policies,
    :entrypoints,
    :initial_inputs,
    :reload,
    :extensions
  ]

  @moduledoc "Executable workflow manifest and stable loading/validation API."

  alias MirrorNeuron.Manifest.Completion
  alias MirrorNeuron.Manifest.Loading
  alias MirrorNeuron.Manifest.Projection
  alias MirrorNeuron.Manifest.Validation

  defdelegate load(manifest), to: Loading
  defdelegate topology(manifest), to: Projection
  defdelegate to_map(manifest), to: Projection
  defdelegate validate(manifest), to: Validation
  defdelegate workflow_step_run_id(step), to: Completion
end
