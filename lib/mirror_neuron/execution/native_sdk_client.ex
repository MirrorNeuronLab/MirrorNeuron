defmodule MirrorNeuron.NativeSdkClient do
  @moduledoc false

  # Each unary native request owns its channel. Leaving a channel alive after
  # the caller returns exhausts the host relay's sockets during supervision.
  # Never retry a command here: its effects may already have committed.
  def call(target, request, timeout, rpc, transport \\ GRPC.Stub) do
    with {:ok, channel} <- transport.connect(target, timeout: timeout) do
      try do
        rpc.(channel, request, timeout: timeout)
      after
        transport.disconnect(channel)
      end
    end
  end
end
