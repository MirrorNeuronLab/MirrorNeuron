defmodule MirrorNeuron.Runtime.NodeAdmission do
  @moduledoc "Durable, owner-local admission and FIFO dispatch for one physical PC."
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.{Hardware, NodeAdapter}

  alias MirrorNeuron.Runtime.{
    AdmissionLedger,
    JobCleanup,
    NativeRequestClaim,
    NodeAdmissionState,
    QueueReconciliation,
    ResourceAllocation
  }

  import AdmissionLedger, only: [entry: 1, mutate: 2, store: 0]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    send(self(), :tick)
    {:ok, %{timer: nil, failure: nil}}
  end

  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    result =
      try do
        reconcile()
      rescue
        _ -> {:error, :unexpected}
      catch
        :exit, _ -> {:error, :unavailable}
      end

    failure =
      case result do
        :ok -> nil
        {:error, category} when is_atom(category) -> category
        _ -> :unavailable
      end

    if failure != state.failure do
      if failure do
        Logger.warning("node admission reconcile owner=#{node_name()} category=#{failure}")
      else
        Logger.info("node admission reconcile owner=#{node_name()} recovered")
      end
    end

    timer = Process.send_after(self(), :tick, 5_000)
    {:noreply, %{state | timer: timer, failure: failure}}
  end

  def handle_cast(:wake, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :tick, 0)}}
  end

  def wake do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :wake)
    :ok
  end

  def ensure_supported do
    hardware = Hardware.info()
    native = hardware[:native_sdk_grpc] || hardware["native_sdk_grpc"] || %{}
    capabilities = native[:capabilities] || native["capabilities"] || []

    if "resource_admission_v2" in capabilities,
      do: :ok,
      else:
        {:error,
         "The selected PC must advertise resource_admission_v2. Update its native runtime and try again."}
  end

  def gate_id(id), do: "admission_" <> Base.encode16(:crypto.hash(:sha256, id), case: :lower)

  def node_name, do: to_string(NodeAdapter.self())

  # Core currently authorizes starts with its node credential (including
  # derived federation credentials). Rotation revokes accepted waiting work.
  # Persist only a digest, never a bearer credential.
  def authority_epoch do
    :crypto.hash(:sha256, to_string(MirrorNeuron.Grpc.Tokens.auth_token()))
    |> Base.encode16(case: :lower)
  end

  def authorized?(epoch) when is_binary(epoch),
    do: MirrorNeuron.Grpc.Tokens.secure_compare(epoch, authority_epoch())

  def authorized?(_), do: false

  defdelegate snapshot(node \\ node_name()), to: AdmissionLedger

  def pin(manifest, generation \\ nil, allocation \\ nil) do
    owner = node_name()
    constraint = %{"attribute" => "node.name", "operator" => "==", "value" => owner}

    policies =
      Map.update(
        manifest.policies || %{},
        "constraints",
        [constraint],
        &[constraint | List.wrap(&1)]
      )

    metadata =
      Map.put(manifest.metadata || %{}, "node_admission", %{
        "owner_node" => owner,
        "capability" => "resource_admission_v2"
      })

    nodes =
      Enum.map(manifest.nodes, fn node ->
        config =
          Map.update(
            node.config || %{},
            "environment",
            %{"MN_SELECTED_RUNTIME_NODE" => owner},
            &Map.put(&1, "MN_SELECTED_RUNTIME_NODE", owner)
          )

        config = Map.put(config, "node_admission_owner", owner)

        config =
          if is_map(allocation) do
            env = MirrorNeuron.ResourceSpec.allocation_env(allocation)

            config
            |> Map.put("resource_allocation", allocation)
            |> Map.update!("environment", &Map.merge(&1, env))
          else
            config
          end

        config =
          if is_integer(generation) do
            config
            |> Map.put("node_admission_generation", generation)
            |> Map.update!(
              "environment",
              &Map.put(&1, "MN_NODE_RESERVATION_GENERATION", to_string(generation))
            )
          else
            config
          end

        %{node | config: config}
      end)

    %{manifest | policies: policies, metadata: metadata, nodes: nodes}
  end

  def retry(job, manifest, request, callback) do
    if get_in(job, ["manifest", "metadata", "node_admission"]) do
      MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(job["job_id"]), fn ->
        with :ok <- JobCleanup.cleanup_sandboxes(job["job_id"], job, []),
             :ok <- retire(job["job_id"]),
             :ok <- QueueReconciliation.import_existing(),
             {:ok, request_entry} <-
               entry(Map.put(job, "manifest", MirrorNeuron.Manifest.to_map(manifest))),
             policy when policy in ["start_now", "enqueue_if_busy"] <-
               Map.get(request, "admission_policy", "start_now"),
             {:ok, receipt} <-
               mutate(if(policy == "start_now", do: "submit_now", else: "submit"), request_entry) do
          if receipt["state"] == "preparing" do
            with {:ok, _} <-
                   mutate("commit", %{
                     "run_id" => job["job_id"],
                     "generation" => receipt["generation"]
                   }),
                 do: callback.(pin(manifest, receipt["generation"], receipt["allocation"]))
          else
            receipt = decorate(receipt)

            queued = %{
              "run_id" => job["run_id"] || job["job_id"],
              "job_id" => job["stable_job_id"],
              "attempt" => job["attempt"] + 1,
              "attempt_id" => "#{job["run_id"] || job["job_id"]}:#{job["attempt"] + 1}",
              "status" => "queued",
              "admission" => receipt,
              "message" => receipt["message"]
            }

            receipts =
              Map.put(job["retry_receipts"] || %{}, request["idempotency_key"], %{
                "request_digest" => request["request_digest"],
                "receipt" => queued
              })

            with {:ok, saved} <-
                   store().persist_terminal_job(job["job_id"], %{
                     "status" => "queued",
                     "queued_retry" => request,
                     "retry_receipts" => receipts,
                     "admission" => Map.put(receipt, "authority_epoch", authority_epoch())
                   }),
                 {:ok, _} <- QueueReconciliation.sync_schedule(saved["job_id"]) do
              wake()
              {:queued, queued}
            end
          end
        end
      end)
    else
      callback.(manifest)
    end
  end

  def claimed?(run_id) do
    with {:ok, state} <- snapshot() do
      Map.has_key?(state["reservations"], run_id)
    else
      _ -> false
    end
  end

  def retire(run_id) do
    with {:ok, state} <- snapshot() do
      cond do
        Map.has_key?(state["reservations"], run_id) ->
          case mutate(
                 "release",
                 Map.take(state["reservations"][run_id], ["run_id", "generation"])
               ) do
            {:ok, _} ->
              wake()
              :ok

            error ->
              error
          end

        true ->
          :ok
      end
    end
  end

  def run(config, run_id, function) do
    if Map.has_key?(config, "node_admission_owner") do
      with true <- config["node_admission_owner"] == node_name(),
           {:ok, state} <- snapshot(),
           true <- Map.has_key?(state["reservations"], run_id),
           false <- NativeRequestClaim.native?(state["reservations"][run_id]),
           true <-
             not Map.has_key?(config, "node_admission_generation") or
               config["node_admission_generation"] ==
                 get_in(state, ["reservations", run_id, "generation"]) do
        function.()
      else
        _ -> {:error, "This PC is not reserved for this run."}
      end
    else
      function.()
    end
  end

  def submit(job), do: reserve(job, "enqueue_if_busy")

  def reserve(job, policy) when policy in ["start_now", "enqueue_if_busy"] do
    with :ok <- QueueReconciliation.import_existing(),
         {:ok, entry} <- entry(job),
         {:ok, receipt} <-
           mutate(if(policy == "start_now", do: "submit_now", else: "submit"), entry) do
      {:ok, decorate(receipt)}
    end
  end

  def reserve(_job, _policy), do: {:error, :invalid_admission_policy}

  defdelegate check(manifest, run_id \\ nil), to: MirrorNeuron.Scheduler.Admission.Inspection
  defdelegate decorate(receipt), to: MirrorNeuron.Scheduler.Admission.Inspection

  def cancel(run_id, expected_revision \\ 0) do
    MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(run_id), fn ->
      with :ok <- queue_revision(run_id, expected_revision),
           {:ok, %{"status" => "queued"}} <- store().fetch_job(run_id),
           {:ok, _} <- store().persist_terminal_job(run_id, %{"status" => "cancelled"}),
           {:ok, _} <- mutate("cancel", %{"run_id" => run_id, "before_start" => true}) do
        _ = QueueReconciliation.sync_schedule(run_id)
        wake()
        :ok
      else
        {:ok, _} -> {:error, :run_already_admitted}
        error -> error
      end
    end)
  end

  def defer(run_id, at, expected_revision \\ 0) do
    with {:ok, datetime, _} <- DateTime.from_iso8601(to_string(at || "")),
         :gt <- DateTime.compare(datetime, DateTime.utc_now()) do
      MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(run_id), fn ->
        with :ok <- queue_revision(run_id, expected_revision),
             {:ok, %{"status" => "queued"} = job} <- store().fetch_job(run_id),
             {:ok, _} <-
               mutate("defer", %{
                 "run_id" => run_id,
                 "not_before" => DateTime.to_iso8601(datetime)
               }),
             {:ok, schedule} <- QueueReconciliation.sync_schedule(job["job_id"]) do
          wake()
          {:ok, schedule}
        else
          {:ok, _} -> {:error, :run_already_admitted}
          error -> error
        end
      end)
    else
      _ -> {:error, "Choose a future date and time."}
    end
  end

  defp queue_revision(_run_id, 0), do: :ok

  defp queue_revision(run_id, expected) do
    with {:ok, schedule} <- store().fetch_schedule("queue_" <> run_id) do
      if schedule["revision"] == expected, do: :ok, else: {:error, :revision_mismatch}
    end
  end

  def command(
        %{"operation" => "node_admission", "action" => "allocation", "run_id" => id} = attrs
      )
      when is_binary(id) do
    with {:ok, state} <- snapshot(),
         %{} = held <- state["reservations"][id],
         false <- NativeRequestClaim.native?(held),
         true <- held["generation"] == attrs["generation"] do
      {:ok, Map.take(held, ~w(run_id job_id generation allocation))}
    else
      _ -> {:error, :stale_node_reservation}
    end
  end

  def command(%{"operation" => "node_admission", "action" => action} = attrs)
      when action in ["request_acquire", "request_release"] do
    run_id = Map.get(attrs, "run_id", "")
    token = Map.get(attrs, "token", "")

    if is_binary(run_id) and byte_size(run_id) <= 160 and is_binary(token) and
         Regex.match?(~r/\A[a-f0-9]{32}\z/, token) do
      request = attrs["request"] || %{"mode" => "exclusive_node"}

      with {:ok, normalized} <-
             ResourceAllocation.request(%{"policies" => %{"resource_allocation" => request}}) do
        result =
          mutate(action, %{
            "run_id" => run_id,
            "token" => token,
            "request" => normalized,
            "generation" => attrs["generation"]
          })

        wake()
        result
      end
    else
      {:error, :invalid_node_admission_command}
    end
  end

  def command(_), do: {:error, :invalid_node_admission_command}

  def cancel_uncommitted(run_id),
    do: mutate("cancel", %{"run_id" => run_id, "before_start" => true})

  defp commit_dispatch(run_id, generation, witness) do
    with {:ok, state} <- snapshot(),
         %{} = held <- state["reservations"][run_id],
         true <- generation == nil or held["generation"] == generation do
      AdmissionLedger.mutate("commit", Map.take(held, ~w(run_id generation)), witness)
    else
      _ -> {:error, :stale_node_reservation}
    end
  end

  def receipt(run_id) do
    with {:ok, state} <- snapshot(),
         do: {:ok, decorate(NodeAdmissionState.receipt(state, run_id))}
  end

  def reconcile, do: QueueReconciliation.reconcile()

  def dispatch(holder) do
    id = holder["run_id"]

    MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(id), fn ->
      with {:ok, job, witness} <- store().fetch_admission_job(id) do
        if job["status"] == "queued" and QueueReconciliation.local_run?(job) do
          with {:ok, _} <- commit_dispatch(id, holder["generation"], witness) do
            result =
              with :ok <- validate_queued_start(job) do
                if is_map(job["queued_retry"]),
                  do: MirrorNeuron.Runtime.RunRetry.dispatch_queued(job),
                  else: MirrorNeuron.Runtime.start_admitted_job(job)
              end

            finish_dispatch(id, result)
          end
        else
          {:ok, id, nil}
        end
      end
    end)
  end

  defp finish_dispatch(_id, {:error, {:admission_wait, _}} = waiting), do: waiting

  defp finish_dispatch(id, result) do
    if match?({:error, _}, result) do
      _ =
        store().persist_terminal_job(id, %{
          "status" => "failed",
          "result" => %{"reason" => "Queued start requires review."}
        })
    end

    _ = QueueReconciliation.sync_schedule(id)
    result
  end

  defp validate_queued_start(job) do
    if authorized?(get_in(job, ["admission", "authority_epoch"])) do
      validate_queued_definition(job)
    else
      {:error, :queued_authorization_revoked}
    end
  end

  defp validate_queued_definition(job) do
    case job["stable_job_id"] do
      nil ->
        :ok

      id ->
        with {:ok, definition} <- store().fetch_job_definition(id),
             true <- definition["status"] == "active",
             queued <- get_in(job, ["manifest", "metadata", "queued_definition"]) || %{},
             true <-
               queued["bundle_fingerprint"] ==
                 get_in(definition, ["bundle_ref", "bundle_fingerprint"]),
             true <-
               queued["configuration_hash"] ==
                 :crypto.hash(
                   :sha256,
                   :erlang.term_to_binary(definition["resolved_configuration"])
                 )
                 |> Base.encode16(case: :lower),
             true <- definition["data_generation"] == job["data_generation"] do
          :ok
        else
          _ -> {:error, :queued_definition_changed}
        end
    end
  end
end
