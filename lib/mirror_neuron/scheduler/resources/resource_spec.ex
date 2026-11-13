defmodule MirrorNeuron.ResourceSpec do
  @moduledoc "Resource specification API shared by admission, placement and runner environments."

  alias MirrorNeuron.ResourceSpec.Environment
  alias MirrorNeuron.ResourceSpec.Inventory
  alias MirrorNeuron.ResourceSpec.Requests
  alias MirrorNeuron.ResourceSpec.Validation

  defdelegate resource_keys(), to: Requests
  defdelegate empty_resources(), to: Requests
  defdelegate normalize_request(resources), to: Requests
  defdelegate scalar_resources(resources), to: Requests
  defdelegate add_gpu_need(spec, count), to: Requests
  defdelegate with_runtime_driver(spec, driver), to: Requests
  defdelegate scheduling_devices(spec), to: Requests
  defdelegate normalize_node_devices(hardware_or_node), to: Inventory
  defdelegate normalize_node_host_paths(node), to: Inventory
  defdelegate normalize_node_host_paths(node, hardware), to: Inventory
  defdelegate normalize_node_runtime_drivers(node), to: Inventory
  defdelegate normalize_node_runtime_drivers(node, hardware), to: Inventory
  defdelegate allocation_env(allocation), to: Environment
  defdelegate validate_manifest(manifest), to: Validation
  defdelegate validate_node(node), to: Validation

  defdelegate infer_runtime_driver(config), to: MirrorNeuron.Runner, as: :driver
end
