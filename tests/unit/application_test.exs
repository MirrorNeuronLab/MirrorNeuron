defmodule MirrorNeuron.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    previous_api_enabled_env = System.get_env("MN_API_ENABLED")
    previous_core_host_env = System.get_env("MN_CORE_HOST")
    previous_grpc_port_env = System.get_env("MN_GRPC_PORT")
    previous_api_enabled_config = Application.get_env(:mirror_neuron, :api_enabled)

    on_exit(fn ->
      restore_env("MN_API_ENABLED", previous_api_enabled_env)
      restore_env("MN_CORE_HOST", previous_core_host_env)
      restore_env("MN_GRPC_PORT", previous_grpc_port_env)
      restore_config(:api_enabled, previous_api_enabled_config)
    end)

    :ok
  end

  test "does not start the gRPC control plane when the API is disabled" do
    System.put_env("MN_API_ENABLED", "false")

    assert MirrorNeuron.Application.grpc_child_specs() == []
  end

  test "starts the gRPC control plane on loopback when the API is enabled" do
    System.put_env("MN_API_ENABLED", "true")
    System.put_env("MN_GRPC_PORT", "50055")
    System.delete_env("MN_CORE_HOST")

    assert [
             {GRPC.Server.Supervisor,
              [
                endpoint: MirrorNeuron.Grpc.Endpoint,
                port: 50055,
                start_server: true,
                ip: {127, 0, 0, 1}
              ]}
           ] = MirrorNeuron.Application.grpc_child_specs()
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_config(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_config(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
