defmodule MirrorNeuron.Runtime.Idempotency do
  @moduledoc false

  use GenServer

  @table :mirror_neuron_idempotency_v1
  @ttl_ms 86_400_000
  @maximum 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, table}
  end

  def run(_scope, key, _payload, operation) when key in [nil, ""], do: operation.()

  def run(scope, key, payload, operation) when is_binary(key) do
    table = table!()
    now = System.system_time(:millisecond)
    prune(table, now)
    record_key = {scope, key}
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(payload))

    case :ets.lookup(table, record_key) do
      [{^record_key, ^fingerprint, result, expires_at}] when expires_at > now ->
        result

      [{^record_key, _other, _result, expires_at}] when expires_at > now ->
        {:error, :idempotency_key_reused}

      _ ->
        result = operation.()
        :ets.insert(table, {record_key, fingerprint, result, now + @ttl_ms})
        trim(table)
        result
    end
  end

  defp table! do
    case :ets.whereis(@table) do
      :undefined ->
        raise "#{inspect(__MODULE__)} is not started"

      table ->
        table
    end
  end

  defp prune(table, now) do
    :ets.select_delete(table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  defp trim(table) do
    overflow = :ets.info(table, :size) - @maximum

    if overflow > 0 do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 3))
      |> Enum.take(overflow)
      |> Enum.each(fn {key, _, _, _} -> :ets.delete(table, key) end)
    end
  end
end
