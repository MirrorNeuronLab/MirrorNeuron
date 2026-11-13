defmodule MirrorNeuron.Runtime.Finalization do
  @moduledoc false
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{EventBus, EventEnvelope}

  def commit(job_id, pending, terminal, event, opts \\ []) do
    persist = Keyword.get(opts, :persist, &RedisStore.persist_job/2)
    finish = Keyword.get(opts, :finish, &RedisStore.persist_terminal_transition/3)
    notify = Keyword.get(opts, :notify, &EventBus.dispatch_persisted/2)

    identity =
      {job_id, terminal[:attempt] || terminal["attempt"],
       terminal[:lease_epoch] || terminal["lease_epoch"], terminal[:status] || terminal["status"]}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    event = event |> Map.put(:event_id, identity) |> EventEnvelope.normalize(job_id)
    intent = %{"terminal" => terminal, "event" => event}

    with {:ok, _} <- persist.(job_id, Map.put(pending, :pending_finalization, intent)),
         {:ok, committed} <- finish.(job_id, terminal, event) do
      notify.(job_id, event)
      {:ok, committed}
    end
  end

  def recover(%{"job_id" => job_id, "pending_finalization" => intent}) do
    with %{"terminal" => terminal, "event" => event} <- intent,
         {:ok, _} <- RedisStore.persist_terminal_transition(job_id, terminal, event) do
      {:ok, terminal}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_finalization_intent}
    end
  end
end
