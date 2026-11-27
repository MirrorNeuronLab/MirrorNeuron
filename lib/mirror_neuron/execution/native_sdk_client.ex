defmodule MirrorNeuron.NativeSdkClient do
  @moduledoc false

  alias MirrorNeuron.Cluster.{FederationChannels, FederationClient}

  def child_spec(_opts) do
    Supervisor.child_spec({FederationChannels, name: __MODULE__}, id: __MODULE__)
  end

  # WIT workers can make hundreds of SetResource calls through the host relay.
  # Each RPC holds a lease and sends the current credential on its own stream.
  def call_shared(target, request, timeout, rpc, pool \\ __MODULE__, transport \\ GRPC.Stub) do
    options = MirrorNeuron.Grpc.SharedResponse.client_options([])
    key = {:native_sdk, node(), target, options}

    FederationClient.invoke_unary(
      key,
      fn -> transport.connect(target, Keyword.put(options, :timeout, timeout)) end,
      fn channel -> rpc.(channel, request, call_options(target, timeout)) end,
      pool,
      min(timeout, 20_000)
    )
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
  end

  # Other native operations own their channel for the duration of the request.
  def call(target, request, timeout, rpc, transport \\ GRPC.Stub) do
    options = MirrorNeuron.Grpc.SharedResponse.client_options(timeout: timeout)

    with {:ok, channel} <- transport.connect(target, options) do
      try do
        rpc.(channel, request, call_options(target, timeout))
      after
        transport.disconnect(channel)
      end
    end
  end

  defp call_options(target, timeout) do
    with {:ok, ^target} <- MirrorNeuron.ModelServices.Requests.native_sdk_grpc_target(),
         token when is_binary(token) and token != "" <-
           MirrorNeuron.Grpc.Tokens.runtime_control_token() do
      [timeout: timeout, metadata: %{"authorization" => "Bearer " <> token}]
    else
      _ -> [timeout: timeout]
    end
  end
end
