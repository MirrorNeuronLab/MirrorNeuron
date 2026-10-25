defmodule MirrorNeuron.Runtime.RunStartRequest do
  @moduledoc "Durable identity and crash reconciliation for keyed start requests."

  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob

  def run(job_id, key, payload, start, store \\ RedisStore, gate \\ &StableJob.with_start_gate/2)

  def run(_job_id, key, payload, start, _store, _gate)
      when key in [nil, ""],
      do: start.(blank(elem(payload, 0)), nil)

  def run(job_id, key, payload, start, store, gate) do
    run_id = elem(payload, 0)
    identity = digest({job_id, key})
    fingerprint = digest(payload)

    gate.("request_" <> identity, fn ->
      with {:ok, request} <- request(store, identity, fingerprint, run_id, job_id),
           {:ok, request} <-
             migrate_policy_fingerprint(store, identity, request, payload, fingerprint),
           true <- request["fingerprint"] == fingerprint do
        case request["result"] do
          %{} = result -> {:ok, result}
          _ -> execute(store, identity, job_id, request, start)
        end
      else
        false -> {:error, :idempotency_key_reused}
        error -> error
      end
    end)
  end

  # Schema migration for requests accepted before admission_policy was added.
  # Preserve their physical run identity; never reinterpret an explicit queue
  # request as an older default start.
  defp migrate_policy_fingerprint(
         store,
         identity,
         request,
         {run, inputs, replace, policy},
         fingerprint
       )
       when policy in ["", "start_now"] do
    if request["fingerprint"] == digest({run, inputs, replace}) do
      store.persist_run_start_request(identity, Map.put(request, "fingerprint", fingerprint))
    else
      {:ok, request}
    end
  end

  defp migrate_policy_fingerprint(_store, _identity, request, _payload, _fingerprint),
    do: {:ok, request}

  defp request(store, identity, fingerprint, run_id, job_id) do
    case store.fetch_run_start_request(identity) do
      {:error, :not_found} ->
        store.persist_run_start_request(identity, %{
          "run_id" => blank(run_id) || JobId.generate_run(job_id),
          "fingerprint" => fingerprint
        })

      result ->
        result
    end
  end

  defp execute(store, identity, job_id, request, start) do
    run_id = request["run_id"]

    result =
      with {:ok, exists} <- store.execution_exists?(run_id) do
        if exists do
          with {:ok, run} <- store.fetch_job(run_id),
               true <-
                 run["stable_job_id"] == job_id and
                   get_in(run, ["manifest", "metadata", "run_start_request"]) == identity do
            {:ok, JobProjection.run(run, run_id) |> Map.put("action", "reconciled")}
          else
            false -> {:error, :run_already_exists}
            error -> error
          end
        else
          start.(run_id, identity)
        end
      end

    case result do
      {:ok, receipt} ->
        # PIDs belong to this process lifetime and never to a durable receipt.
        receipt = receipt |> Map.drop([:pid, "pid"]) |> Jason.encode!() |> Jason.decode!()

        with {:ok, _} <-
               store.persist_run_start_request(identity, Map.put(request, "result", receipt)),
             do: {:ok, receipt}

      error ->
        error
    end
  end

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
