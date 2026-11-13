defmodule MirrorNeuron.Runtime.AdmissionLedger do
  @moduledoc false
  require Logger
  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{NodeAdmission, NodeAdmissionState, ResourceAllocation}

  def snapshot(node \\ NodeAdmission.node_name()) do
    if store() != RedisStore or Process.whereis(MirrorNeuron.Redis.Connection) do
      case store().fetch_node_admission(node) do
        {:ok, state} -> NodeAdmissionState.decode(state)
        error -> error
      end
    else
      {:error, :node_admission_unavailable}
    end
  end

  def entry(job) do
    with {:ok, request} <- ResourceAllocation.request(job["manifest"] || %{}) do
      {:ok,
       %{
         "run_id" => job["job_id"],
         "job_id" => job["stable_job_id"],
         "job_name" => job["job_name"],
         "enqueued_at" => job["submitted_at"],
         "request" => request
       }}
    end
  end

  def capacity do
    with {:ok, limits} <- MirrorNeuron.Resource.admission_limits(),
         do: {:ok, ResourceAllocation.capacity(Hardware.info(), limits)}
  end

  def mutate(operation, attrs, witness \\ nil) do
    result = mutate(operation, attrs, witness, 50)

    case result do
      {:error, reason}
      when reason in [
             :stale_node_reservation,
             :admission_run_changed,
             :node_admission_unavailable
           ] ->
        # Request tokens and arbitrary backend messages never enter this sink.
        id = attrs["run_id"] || ""

        run =
          if id != "" and id != "request_" <> to_string(attrs["token"]) and
               Regex.match?(~r/\A[A-Za-z0-9_.-]{1,160}\z/, id) do
            id
          else
            "unscoped"
          end

        generation =
          if attrs["generation"] in 0..9_223_372_036_854_775_807,
            do: attrs["generation"],
            else: "unknown"

        Logger.debug(fn ->
          "node admission operation=#{operation} owner=#{NodeAdmission.node_name()} run=#{run} generation=#{generation} category=#{reason}"
        end)

      _ ->
        :ok
    end

    result
  end

  defp mutate(_op, _attrs, _witness, 0), do: {:error, :node_admission_busy}

  defp mutate(op, attrs, witness, remaining) do
    with {:ok, state} <- snapshot(),
         {:ok, attrs} <- with_capacity(op, attrs, state),
         {:ok, next, result} <- NodeAdmissionState.transition(state, op, attrs) do
      if next == state do
        {:ok, result}
      else
        case store().compare_node_admission(
               NodeAdmission.node_name(),
               state["version"],
               Map.put(next, "version", state["version"] + 1),
               witness
             ) do
          :ok -> {:ok, result}
          {:error, :admission_conflict} -> mutate(op, attrs, witness, remaining - 1)
          error -> error
        end
      end
    end
  end

  defp with_capacity(op, attrs, state) do
    needed =
      case op do
        "promote" ->
          state["queue"] != [] or state["deferred"] != []

        "request_acquire" ->
          attrs["run_id"] == "" and not Map.has_key?(state["requests"], attrs["token"])

        op when op in ["submit", "submit_now"] ->
          NodeAdmissionState.receipt(state, attrs["run_id"])["state"] == "unreserved"

        _ ->
          false
      end

    if needed do
      with {:ok, capacity} <- capacity(), do: {:ok, Map.put(attrs, "capacity", capacity)}
    else
      {:ok, attrs}
    end
  end

  def store, do: Application.get_env(:mirror_neuron, :node_admission_store, RedisStore)
end
