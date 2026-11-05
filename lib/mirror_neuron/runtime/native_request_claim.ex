defmodule MirrorNeuron.Runtime.NativeRequestClaim do
  @moduledoc false

  # ":" is outside the durable Run ID alphabet. Reports can identify a claim
  # without disclosing the bearer token needed to release it.
  def id(token), do: "request_:" <> Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  def native?(%{"claim_kind" => "native_request"}), do: true

  def native?(_), do: false

  def report_entry(key, entry), do: {key, Map.delete(entry, "claim_kind")}

  def entry(token, request, capacity) do
    %{
      "run_id" => id(token),
      "claim_kind" => "native_request",
      "request" => request,
      "capacity" => capacity
    }
  end
end
