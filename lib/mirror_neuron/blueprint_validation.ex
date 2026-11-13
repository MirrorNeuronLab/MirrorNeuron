defmodule MirrorNeuron.BlueprintValidation do
  @moduledoc "Blueprint input and hardware preflight API."

  alias MirrorNeuron.BlueprintValidation.InputRules
  alias MirrorNeuron.BlueprintValidation.Requirements

  defdelegate force?(manifest), to: InputRules
  defdelegate run_input_validation(bundle), to: InputRules
  defdelegate check_requirements(manifest), to: Requirements
  defdelegate check_requirements(manifest, snapshot), to: Requirements
  defdelegate requirement_violations(requirements, snapshot), to: Requirements
end
