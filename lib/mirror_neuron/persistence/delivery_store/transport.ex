defmodule MirrorNeuron.Persistence.DeliveryStore.Transport do
  @moduledoc "Routes protected lanes separately and preserves durability barriers."

  alias MirrorNeuron.Persistence.RedisStore

  def command(args) do
    protected =
      Enum.any?(args, fn arg ->
        is_binary(arg) and String.starts_with?(arg, RedisStore.storage_key(["job"]) <> ":") and
          String.contains?(arg, ["__mn_command__/", "__mn_control__/"])
      end)

    if protected,
      do: MirrorNeuron.Persistence.ProtectedRedis.command("controls", args),
      else: RedisStore.storage_command(args)
  end

  def pipeline([]), do: {:ok, []}

  def pipeline(commands), do: RedisStore.storage_pipeline(commands)

  def wait_for_replicas(agent_id) do
    if String.starts_with?(agent_id, ["__mn_command__/", "__mn_control__/"]),
      do: MirrorNeuron.Persistence.ProtectedRedis.barrier("controls"),
      else: RedisStore.storage_barrier()
  end

  def format_reason(reason), do: reason
end
