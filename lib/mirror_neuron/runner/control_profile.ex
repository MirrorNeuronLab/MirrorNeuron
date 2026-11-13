defmodule MirrorNeuron.Runner.ControlProfile do
  @moduledoc "Execution semantics shared by SDK workers, independent of their process adapter."

  # This SDK entrypoint exclusively executes monitored_service blocks. Ordinary
  # handlers must never acquire permission to replay an uncertain invocation.
  def sdk(config) do
    if get_in(config, ["environment", "MN_WORKFLOW_STEP_HANDLER"]) ==
         "mn_sdk.integrations.block_auxiliary" do
      service()
    else
      %{restart_after_stop: false, readiness: :invocation}
    end
  end

  def service, do: %{restart_after_stop: true, readiness: :reported}
end
