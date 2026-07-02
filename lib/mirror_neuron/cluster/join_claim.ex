defmodule MirrorNeuron.Cluster.JoinClaim do
  @moduledoc false

  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Config

  @claim_file "cluster-join-claim.json"
  @pending_ttl_ms 120_000
  @version 1

  def reserve(owner, attrs \\ %{}) do
    owner = normalize_owner(owner)

    if owner == "" do
      {:error, :missing_owner}
    else
      locked(fn -> reserve_claim(owner, stringify_map(attrs), now()) end)
    end
  end

  def confirm(owner, attrs \\ %{}) do
    owner = normalize_owner(owner)

    if owner == "" do
      {:error, :missing_owner}
    else
      locked(fn -> confirm_claim(owner, stringify_map(attrs), now()) end)
    end
  end

  def clear(owner) do
    owner = normalize_owner(owner)

    locked(fn ->
      case read_claim() do
        {:ok, %{"owner_node" => ^owner}} ->
          _ = File.rm(path())
          :ok

        {:ok, %{"owner_node" => existing_owner}} when owner != "" ->
          {:error, {:owner_mismatch, existing_owner}}

        {:ok, _claim} when owner == "" ->
          _ = File.rm(path())
          :ok

        {:error, :missing} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end)
  end

  def read do
    read_claim()
  end

  def path do
    Path.join(mn_home(), @claim_file)
  end

  def pending_ttl_ms, do: @pending_ttl_ms

  defp reserve_claim(owner, attrs, now) do
    case read_claim() do
      {:ok, claim} ->
        reserve_existing_claim(claim, owner, attrs, now)

      {:error, _reason} ->
        reserve_without_active_claim(owner, attrs, now)
    end
  end

  defp reserve_existing_claim(%{"owner_node" => owner} = claim, owner, attrs, now) do
    claim
    |> Map.merge(attrs)
    |> Map.put("state", Map.get(claim, "state", "pending"))
    |> Map.put("owner_node", owner)
    |> Map.put("updated_at", timestamp(now))
    |> maybe_refresh_pending_expiry(now)
    |> write_claim()
  end

  defp reserve_existing_claim(claim, owner, attrs, now) do
    if active_claim?(claim, now) do
      {:error, {:already_joined, Map.get(claim, "owner_node")}}
    else
      reserve_without_active_claim(owner, attrs, now)
    end
  end

  defp reserve_without_active_claim(owner, attrs, now) do
    case connected_owner_conflict(owner) do
      {:error, existing_owner} ->
        {:error, {:already_joined, existing_owner}}

      :ok ->
        owner
        |> new_pending_claim(attrs, now)
        |> write_claim()
    end
  end

  defp confirm_claim(owner, attrs, now) do
    case read_claim() do
      {:ok, %{"owner_node" => ^owner} = claim} ->
        claim
        |> Map.merge(attrs)
        |> Map.put("state", "confirmed")
        |> Map.put("owner_node", owner)
        |> Map.put("confirmed_at", timestamp(now))
        |> Map.put("updated_at", timestamp(now))
        |> Map.delete("expires_at")
        |> write_claim()
        |> case do
          {:ok, _claim} -> :ok
          error -> error
        end

      {:ok, %{"owner_node" => existing_owner} = claim} ->
        if active_claim?(claim, now) do
          {:error, {:already_joined, existing_owner}}
        else
          confirm_without_active_claim(owner, attrs, now)
        end

      {:error, _reason} ->
        confirm_without_active_claim(owner, attrs, now)
    end
  end

  defp confirm_without_active_claim(owner, attrs, now) do
    case connected_owner_conflict(owner) do
      {:error, existing_owner} ->
        {:error, {:already_joined, existing_owner}}

      :ok ->
        owner
        |> new_pending_claim(attrs, now)
        |> Map.put("state", "confirmed")
        |> Map.put("confirmed_at", timestamp(now))
        |> Map.delete("expires_at")
        |> write_claim()
        |> case do
          {:ok, _claim} -> :ok
          error -> error
        end
    end
  end

  defp new_pending_claim(owner, attrs, now) do
    attrs
    |> Map.merge(%{
      "version" => @version,
      "state" => "pending",
      "owner_node" => owner,
      "claimed_at" => timestamp(now),
      "updated_at" => timestamp(now),
      "expires_at" => timestamp(DateTime.add(now, @pending_ttl_ms, :millisecond))
    })
  end

  defp maybe_refresh_pending_expiry(%{"state" => "pending"} = claim, now) do
    claim
    |> Map.put("expires_at", timestamp(DateTime.add(now, @pending_ttl_ms, :millisecond)))
  end

  defp maybe_refresh_pending_expiry(claim, _now), do: claim

  defp active_claim?(%{"state" => "confirmed", "owner_node" => owner}, _now) do
    connected_owner?(owner)
  end

  defp active_claim?(%{"state" => "confirmed"}, _now), do: false

  defp active_claim?(%{"state" => "pending", "expires_at" => expires_at}, now)
       when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} -> DateTime.compare(expires_at, now) == :gt
      _ -> false
    end
  end

  defp active_claim?(_claim, _now), do: false

  defp connected_owner?(owner) do
    owner = normalize_owner(owner)

    owner != "" and
      NodeAdapter.list()
      |> Enum.map(&to_string/1)
      |> Enum.any?(&(&1 == owner))
  rescue
    _ -> false
  end

  defp connected_owner_conflict(owner) do
    connected =
      NodeAdapter.list()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      connected == [] -> :ok
      owner in connected -> :ok
      true -> {:error, List.first(connected)}
    end
  rescue
    _ -> :ok
  end

  defp read_claim do
    claim_path = path()

    with true <- File.regular?(claim_path),
         {:ok, raw} <- File.read(claim_path),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :missing}
      _ -> {:error, :invalid}
    end
  end

  defp write_claim(claim) do
    claim_path = path()
    tmp_path = "#{claim_path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(claim_path)),
         {:ok, encoded} <- Jason.encode(claim),
         :ok <- File.write(tmp_path, encoded <> "\n"),
         :ok <- File.rename(tmp_path, claim_path) do
      {:ok, claim}
    else
      error ->
        _ = File.rm(tmp_path)
        error
    end
  end

  defp locked(fun) do
    :global.trans({__MODULE__, node()}, fun, [node()], 5_000)
  end

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_map(_map), do: %{}

  defp normalize_owner(owner) do
    owner
    |> to_string()
    |> String.trim()
  end

  defp now, do: DateTime.utc_now()

  defp timestamp(datetime), do: DateTime.to_iso8601(datetime)

  defp mn_home do
    Config.optional_string("MN_HOME", :home) || Path.expand("~/.mn")
  end
end
