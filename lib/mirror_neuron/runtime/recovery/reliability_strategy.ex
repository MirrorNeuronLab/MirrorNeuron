defmodule MirrorNeuron.Runtime.ReliabilityStrategy do
  @moduledoc false

  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Manifest

  @active_statuses ["healthy", "joining"]
  @default_stable_ms 10_000

  def resolve(%Manifest{} = manifest, opts \\ []) do
    requested = requested_recovery_policy(manifest)
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> cluster_snapshot(opts) end)
    manifest_ref = Keyword.get(opts, :manifest_ref, %{})

    {effective, degraded?, reason} =
      resolve_effective_policy(requested, manifest, manifest_ref, snapshot)

    %{
      "mode" => snapshot.mode,
      "requested_recovery_policy" => requested,
      "effective_recovery_policy" => effective,
      "reliability_degraded" => degraded?,
      "degraded" => degraded?,
      "reason" => reason,
      "observed_nodes" => snapshot.observed_nodes,
      "observed_at" => snapshot.observed_at
    }
  end

  def cluster_snapshot(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
    stable_ms = Keyword.get_lazy(opts, :stable_ms, &stable_ms/0)
    connected_nodes = connected_node_names(Keyword.get(opts, :connected_nodes))
    node_states = Keyword.get_lazy(opts, :node_states, &NodeState.list/0)

    observed_states =
      node_states
      |> ensure_self_state(connected_nodes)
      |> Enum.filter(&healthy_runtime_state?(&1, connected_nodes, now, stable_ms))

    observed_nodes =
      observed_states
      |> Enum.map(&Map.get(&1, "node"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      mode: if(length(observed_nodes) >= 2, do: "multi_node", else: "single_node"),
      observed_nodes: observed_nodes,
      observed_at: timestamp(now),
      node_states: observed_states
    }
  end

  def cluster_recoverable_now?(job, snapshot \\ cluster_snapshot()) when is_map(job) do
    with %{"manifest" => manifest_map} when is_map(manifest_map) <- job,
         {:ok, manifest} <- Manifest.load(manifest_map) do
      cluster_recoverable?(manifest, Map.get(job, "manifest_ref", %{}), snapshot) == :ok
    else
      _ -> false
    end
  end

  def requested_recovery_policy(%Manifest{policies: policies}) do
    case Map.get(policies || %{}, "recovery_mode") do
      nil -> "auto"
      "" -> "auto"
      value -> to_string(value)
    end
  end

  defp resolve_effective_policy("manual_recover", _manifest, _manifest_ref, snapshot) do
    {"manual_recover", false, "manual recovery requested on #{snapshot.mode}"}
  end

  defp resolve_effective_policy("local_restart", _manifest, _manifest_ref, snapshot) do
    {"local_restart", false, "local recovery requested on #{snapshot.mode}"}
  end

  defp resolve_effective_policy("cluster_recover", manifest, manifest_ref, snapshot) do
    case cluster_recoverable?(manifest, manifest_ref, snapshot) do
      :ok ->
        {"cluster_recover", false, "cluster recovery enabled"}

      {:error, reason} ->
        {"local_restart", true, reason}
    end
  end

  defp resolve_effective_policy(_auto, manifest, manifest_ref, snapshot) do
    case cluster_recoverable?(manifest, manifest_ref, snapshot) do
      :ok ->
        {"cluster_recover", false, "auto selected cluster recovery"}

      {:error, reason} ->
        {"local_restart", false, reason}
    end
  end

  defp cluster_recoverable?(_manifest, _manifest_ref, %{mode: mode})
       when mode != "multi_node" do
    {:error, "fewer than 2 healthy connected runtime nodes observed"}
  end

  defp cluster_recoverable?(manifest, manifest_ref, snapshot) do
    cond do
      not archived_bundle?(manifest_ref) ->
        {:error, "recovery bundle is not archived in durable cluster storage"}

      profile = missing_remote_profile(manifest, snapshot) ->
        {:error, "no alternate healthy runtime node advertises execution profile #{profile}"}

      true ->
        :ok
    end
  end

  defp archived_bundle?(manifest_ref) when is_map(manifest_ref) do
    storage = manifest_ref["bundle_storage"] || manifest_ref[:bundle_storage]
    fingerprint = manifest_ref["bundle_fingerprint"] || manifest_ref[:bundle_fingerprint]

    storage in ["redis", "shared_fs", "shared_fs_cas"] and is_binary(fingerprint) and
      fingerprint != ""
  end

  defp archived_bundle?(_manifest_ref), do: false

  defp missing_remote_profile(manifest, snapshot) do
    manifest.nodes
    |> Enum.map(&Profile.profile_name(&1.config))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find(fn profile ->
      not Enum.any?(snapshot.node_states, &remote_profile_node?(&1, profile))
    end)
  end

  defp remote_profile_node?(node_state, profile) do
    node_state["node"] != to_string(Node.self()) and Profile.eligible_node?(profile, node_state)
  end

  defp healthy_runtime_state?(node_state, connected_nodes, now, stable_ms) do
    node = Map.get(node_state, "node")

    node in connected_nodes and
      Map.get(node_state, "status", "offline") in @active_statuses and
      runtime_node?(node_state) and
      stable_state?(node_state, now, stable_ms)
  end

  defp runtime_node?(node_state) do
    role = Map.get(node_state, "node_role") || Map.get(node_state, "role") || "runtime"
    role != "control"
  end

  defp stable_state?(_node_state, _now, stable_ms) when stable_ms <= 0, do: true

  defp stable_state?(node_state, now, stable_ms) do
    case Map.get(node_state, "updated_at") do
      updated_at when is_binary(updated_at) ->
        with {:ok, updated, _offset} <- DateTime.from_iso8601(updated_at) do
          DateTime.diff(now, updated, :millisecond) >= stable_ms
        else
          _ -> false
        end

      _ ->
        true
    end
  end

  defp ensure_self_state(node_states, connected_nodes) do
    self_name = to_string(Node.self())

    if self_name in connected_nodes and not Enum.any?(node_states, &(&1["node"] == self_name)) do
      [%{"node" => self_name, "status" => "healthy", "node_role" => "runtime"} | node_states]
    else
      node_states
    end
  end

  defp connected_node_names(nil) do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
  end

  defp connected_node_names(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp stable_ms do
    config_nonnegative_integer(
      "MN_CLUSTER_HEALTH_STABLE_MS",
      :cluster_health_stable_ms,
      @default_stable_ms
    )
  end

  defp config_nonnegative_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> parse_nonnegative_integer(value, default)
    end
  end

  defp parse_nonnegative_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp timestamp(%DateTime{} = datetime),
    do: DateTime.to_iso8601(DateTime.truncate(datetime, :millisecond))
end
