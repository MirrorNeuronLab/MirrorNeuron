defmodule MirrorNeuron.Runtime.NativeRequestClaim do
  @moduledoc false

  # ":" is outside the durable Run ID alphabet. Reports can identify a claim
  # without disclosing the bearer token needed to release it.
  def id(token), do: "request_:" <> Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  def native?(%{"claim_kind" => "native_request"}), do: true

  def native?(
        %{
          "run_id" => "request_" <> _,
          "committed" => false,
          "request" => %{},
          "allocation" => %{}
        } = entry
      ),
      do: not Enum.any?(~w(job_id job_name enqueued_at), &Map.has_key?(entry, &1))

  def native?(_), do: false

  # An old interrupted writer may leave an anonymous holder without a token.
  # Keep its capacity charged and hide its bearer-shaped name in projections.
  def report_entry("request_" <> token = key, entry) do
    if native?(entry) and entry["claim_kind"] == nil do
      private = id(token)
      {private, Map.put(entry, "run_id", private)}
    else
      {key, Map.delete(entry, "claim_kind")}
    end
  end

  def report_entry(key, entry), do: {key, entry}

  def entry(token, request, capacity) do
    %{
      "run_id" => id(token),
      "claim_kind" => "native_request",
      "request" => request,
      "capacity" => capacity
    }
  end

  def upgrade(state) do
    # Every durable Run entry includes job_id, job_name and enqueued_at,
    # including nil values. A matching name alone never proves ownership.
    Enum.reduce(state["reservations"], state, fn
      {"request_" <> token = old, %{"run_id" => old_id} = held}, acc when old == old_id ->
        if held["claim_kind"] == nil and native?(held) do
          private = id(token)

          if Map.has_key?(acc["reservations"], private) do
            acc
          else
            reservations =
              acc["reservations"]
              |> Map.delete(old)
              |> Map.put(
                private,
                Map.merge(held, %{"run_id" => private, "claim_kind" => "native_request"})
              )

            %{acc | "reservations" => reservations}
          end
        else
          acc
        end

      _, acc ->
        acc
    end)
  end
end
