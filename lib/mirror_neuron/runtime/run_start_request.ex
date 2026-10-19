defmodule MirrorNeuron.Runtime.RunStartRequest do
  @moduledoc "Durable identity and crash reconciliation for keyed start requests."

  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob

  def run(job_id, key, payload, start, store \\ RedisStore, gate \\ &StableJob.with_start_gate/2)

  def run(_job_id, key, {run_id, _inputs, _replace}, start, _store, _gate)
      when key in [nil, ""],
      do: start.(blank(run_id), nil)

  def run(job_id, key, {run_id, _, _} = payload, start, store, gate) do
    identity = digest({job_id, key})
    fingerprint = digest(payload)

    gate.("request_" <> identity, fn ->
      with {:ok, request} <- request(store, identity, fingerprint, run_id),
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

  defp request(store, identity, fingerprint, run_id) do
    case store.fetch_run_start_request(identity) do
      {:error, :not_found} ->
        store.persist_run_start_request(identity, %{
          "run_id" => blank(run_id) || "run_" <> identity,
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
