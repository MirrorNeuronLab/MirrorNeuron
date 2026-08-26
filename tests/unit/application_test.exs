defmodule MirrorNeuron.ApplicationTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Application

  setup do
    previous_core_host_env = System.get_env("MN_CORE_HOST")
    previous_grpc_port_env = System.get_env("MN_GRPC_PORT")

    on_exit(fn ->
      restore_env("MN_CORE_HOST", previous_core_host_env)
      restore_env("MN_GRPC_PORT", previous_grpc_port_env)
    end)

    :ok
  end

  test "starts the gRPC control plane on loopback" do
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
           ] = Application.grpc_child_specs()
  end

  describe "grpc_bind_opts/1" do
    test "binds empty and localhost values to IPv4 loopback" do
      assert Application.grpc_bind_opts("") == [ip: {127, 0, 0, 1}]
      assert Application.grpc_bind_opts("localhost") == [ip: {127, 0, 0, 1}]
      assert Application.grpc_bind_opts("LOCALHOST") == [ip: {127, 0, 0, 1}]
      assert Application.grpc_bind_opts(" localhost ") == [ip: {127, 0, 0, 1}]
    end

    test "passes through IP literal bind hosts" do
      assert Application.grpc_bind_opts("0.0.0.0") == [ip: {0, 0, 0, 0}]
      assert Application.grpc_bind_opts("127.0.0.1") == [ip: {127, 0, 0, 1}]
      assert Application.grpc_bind_opts("::1") == [net: :inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]
    end

    test "fails closed to IPv4 loopback for invalid bind hosts" do
      assert Application.grpc_bind_opts("example.com") == [ip: {127, 0, 0, 1}]
      assert Application.grpc_bind_opts("not an ip") == [ip: {127, 0, 0, 1}]
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
