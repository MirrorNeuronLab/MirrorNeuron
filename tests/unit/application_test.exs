defmodule MirrorNeuron.ApplicationTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Application

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
end
