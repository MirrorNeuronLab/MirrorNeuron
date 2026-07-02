defmodule MirrorNeuron.Grpc.NetworkOnly do
  @moduledoc false

  def enabled? do
    MirrorNeuron.Config.boolean("MN_NETWORK_ONLY", :network_only)
  end

  def reject_if_enabled!(operation) do
    if enabled?() do
      raise GRPC.RPCError,
        status: GRPC.Status.permission_denied(),
        message: "#{operation} is disabled while MN_NETWORK_ONLY=true"
    end

    :ok
  end
end
