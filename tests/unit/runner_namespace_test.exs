defmodule MirrorNeuron.RunnerNamespaceTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Runner.OpenShell

  test "OpenShell has a runner namespace entrypoint" do
    assert {:module, OpenShell} = Code.ensure_loaded(OpenShell)
    assert function_exported?(OpenShell, :run, 3)
  end

  test "OpenShell runner namespace infers openshell runtime driver" do
    assert ResourceSpec.infer_runtime_driver(%{
             "runner_module" => "MirrorNeuron.Runner.OpenShell"
           }) == "openshell"
  end
end
