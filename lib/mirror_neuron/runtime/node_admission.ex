defmodule MirrorNeuron.Runtime.NodeAdmission do
  @moduledoc "Durable, owner-local admission and FIFO dispatch for one physical PC."
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.{Hardware, NodeAdapter}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{JobCleanup, NodeAdmissionState, ResourceAllocation}
  @terminal ~w(completed failed cancelled)
  @active ~w(pending validated scheduled running paused pausing resuming cancelling)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    send(self(), :tick)
    {:ok, %{timer: nil}}
  end

  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    reconcile()
    timer = Process.send_after(self(), :tick, 5_000)
    {:noreply, %{state | timer: timer}}
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

  def snapshot(node \\ node_name()) do
    if store() != RedisStore or Process.whereis(MirrorNeuron.Redis.Connection) do
      case store().fetch_node_admission(node) do
        {:ok, state} -> {:ok, NodeAdmissionState.upgrade(state)}
        error -> error
      end
    else
      {:error, :node_admission_unavailable}
    end
  end

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
             :ok <- import_existing(),
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
                 {:ok, _} <- persist_queue_schedule(saved) do
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
      Map.has_key?(state["reservations"], run_id) or run_id in state["legacy"]
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

        run_id in state["legacy"] ->
          case mutate("release_legacy", %{"run_id" => run_id}) do
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
           true <- Map.has_key?(state["reservations"], run_id) or run_id in state["legacy"],
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
    with :ok <- import_existing(),
         {:ok, entry} <- entry(job),
         {:ok, receipt} <-
           mutate(if(policy == "start_now", do: "submit_now", else: "submit"), entry) do
      {:ok, decorate(receipt)}
    end
  end

  def reserve(_job, _policy), do: {:error, :invalid_admission_policy}

  defp entry(job) do
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

  def check(manifest, run_id \\ nil) do
    with {:ok, state} <- snapshot(), {:ok, request} <- ResourceAllocation.request(manifest) do
      retained =
        is_binary(run_id) and Map.has_key?(state["reservations"], run_id) and
          match?({:ok, %{"status" => "paused"}}, store().fetch_job(run_id))

      state =
        if run_id,
          do: %{state | "reservations" => Map.delete(state["reservations"], run_id)},
          else: state

      capacity = ResourceAllocation.capacity(Hardware.info(), MirrorNeuron.Resource.limits())

      allocations =
        NodeAdmissionState.allocations(state) ++
          if(state["legacy"] == [], do: [], else: [%{"mode" => "exclusive_node"}])

      result =
        if retained and capacity["telemetry_current"] != false,
          do: %{"status" => "runnable_now", "blockers" => []},
          else: ResourceAllocation.check(request, capacity, allocations)

      result =
        if result["status"] == "runnable_now" and not retained do
          case NodeAdmissionState.transition(state, "submit_now", %{
                 "run_id" => "admission_check",
                 "request" => request,
                 "capacity" => capacity
               }) do
            {:ok, _, _} ->
              result

            _ ->
              Map.merge(result, %{
                "status" => "runnable_later",
                "blockers" => [
                  %{
                    "code" => "MN_RESOURCE_EXHAUSTED",
                    "resource" => "queue_priority",
                    "node_index" => 1
                  }
                ]
              })
          end
        else
          result
        end

      result =
        if result["status"] in ["runnable_now", "runnable_later"] do
          case MirrorNeuron.Scheduler.plan(pin(manifest), jobs: [], exclusive_run: true) do
            {:ok, _} ->
              result

            {:error, _reason} ->
              %{
                "status" => "not_runnable",
                "blockers" => [
                  %{
                    "code" => "MN_PLACEMENT_UNSATISFIED",
                    "resource" => "placement",
                    "node_index" => 1
                  }
                ]
              }
          end
        else
          result
        end

      {:ok,
       result
       |> Map.drop(["allocation"])
       |> Map.put("owner_node", node_name())
       |> Map.put("node_label", node_label())
       |> Map.put("observed_at", MirrorNeuron.Runtime.timestamp())}
    end
  end

  defp node_label do
    hardware = Hardware.info()
    get_in(hardware, [:platform, :display_name]) || node_name()
  end

  def decorate(receipt) do
    hardware = Hardware.info()
    label = get_in(hardware, [:platform, :display_name]) || node_name()
    blocker = receipt["blocked_by"] || %{}

    blocking_job =
      case blocker["run_id"] && store().fetch_job(blocker["run_id"]) do
        {:ok, job} -> job
        _ -> %{}
      end

    status = blocking_job["status"] || blocker["status"]

    suffix =
      cond do
        status == "paused" -> " (paused)"
        status in @terminal -> " (cleanup in progress)"
        true -> ""
      end

    blocked = (blocker["job_name"] || blocking_job["job_name"] || "the current run") <> suffix

    automatic =
      if is_integer(receipt["position"]) and receipt["position"] > 1,
        do: "It will start automatically when earlier runs finish.",
        else: "It will start automatically when the current run finishes."

    receipt =
      if map_size(blocker) > 0,
        do:
          Map.put(
            receipt,
            "blocked_by",
            Map.merge(blocker, %{"job_name" => blocked, "status" => status})
          ),
        else: receipt

    receipt
    |> Map.put("owner_node", node_name())
    |> Map.put("node_label", label)
    |> Map.put(
      "message",
      if(receipt["state"] == "queued",
        do:
          if(receipt["not_before"],
            do:
              "Scheduled on #{label} for #{receipt["not_before"]}. It will wait automatically if the PC is busy.",
            else: "Queued on #{label} behind #{blocked}. #{automatic}"
          ),
        else:
          if(receipt["state"] == "preparing",
            do: "Resources reserved on #{label}.",
            else: "No active reservation for this run on #{label}."
          )
      )
    )
  end

  def cancel(run_id, expected_revision \\ 0) do
    MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(run_id), fn ->
      with :ok <- queue_revision(run_id, expected_revision),
           {:ok, %{"status" => "queued"}} <- store().fetch_job(run_id),
           {:ok, _} <- store().persist_terminal_job(run_id, %{"status" => "cancelled"}),
           {:ok, _} <- mutate("cancel", %{"run_id" => run_id, "before_start" => true}) do
        _ = store().delete_schedule("queue_" <> run_id)
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
             {:ok, schedule} <- persist_queue_schedule(job) do
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

  defp commit_dispatch(run_id) do
    with {:ok, state} <- snapshot(),
         %{} = held <- state["reservations"][run_id] do
      mutate("commit", Map.take(held, ~w(run_id generation)))
    else
      _ -> {:error, :stale_node_reservation}
    end
  end

  def receipt(run_id) do
    with {:ok, state} <- snapshot(),
         do: {:ok, decorate(NodeAdmissionState.receipt(state, run_id))}
  end

  def reconcile do
    with :ok <- import_existing(), {:ok, state} <- snapshot() do
      Enum.each(state["queue"] ++ Map.get(state, "deferred", []), fn entry ->
        case store().fetch_job(entry["run_id"]) do
          {:ok, job} -> persist_queue_schedule(job)
          _ -> :ok
        end
      end)

      Enum.each(state["legacy"], &cleanup_legacy/1)

      Enum.each(state["requests"], fn {token, run} ->
        if run == "" do
          case MirrorNeuron.ModelServices.native_resource_command(%{
                 "operation" => "reconcile_request_lease",
                 "token" => token
               }) do
            {:ok, %{"status" => "drained"}} -> mutate("request_release", %{"token" => token})
            _ -> :ok
          end
        end
      end)

      Enum.each(Map.values(state["reservations"]), fn reservation ->
        unless String.starts_with?(reservation["run_id"], "request_"),
          do: reconcile_holder(reservation)
      end)

      with {:ok, reservations} <- mutate("promote", %{}) do
        Enum.each(reservations, &dispatch/1)
      end
    end

    :ok
  rescue
    _ -> Logger.warning("node admission reconciliation failed; reservations retained")
  catch
    _, _ -> Logger.warning("node admission reconciliation unavailable; reservations retained")
  end

  def dispatch(holder) do
    case store().fetch_job(holder["run_id"]) do
      {:ok, %{"status" => "queued"} = job} ->
        # The node claim and this execution's fenced gate prevent concurrent
        # ticks, schedule dispatch and restart recovery from launching twice.
        MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(job["job_id"]), fn ->
          case store().fetch_job(job["job_id"]) do
            {:ok, %{"status" => "queued"} = current} ->
              result =
                case with(
                       :ok <- validate_queued_start(current),
                       {:ok, _} <- commit_dispatch(current["job_id"]),
                       do: :ok
                     ) do
                  :ok ->
                    if is_map(current["queued_retry"]),
                      do: MirrorNeuron.Runtime.RunRetry.dispatch_queued(current),
                      else: MirrorNeuron.Runtime.start_admitted_job(current)

                  error ->
                    error
                end

              case result do
                {:ok, _, _} ->
                  :ok

                {:error, {:admission_wait, _}} ->
                  :ok

                {:error, _reason} ->
                  _ =
                    store().persist_terminal_job(job["job_id"], %{
                      "status" => "failed",
                      "result" => %{"reason" => "Queued start requires review."}
                    })
              end

              unless match?({:error, {:admission_wait, _}}, result),
                do: store().delete_schedule("queue_" <> job["job_id"])

              result

            {:ok, _} ->
              {:ok, job["job_id"], nil}

            error ->
              error
          end
        end)

      {:ok, job} ->
        {:ok, job["job_id"], nil}

      error ->
        error
    end
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

  defp reconcile_holder(holder) do
    MirrorNeuron.Runtime.StableJob.with_start_gate(gate_id(holder["run_id"]), fn ->
      missing = "job #{holder["run_id"]} was not found"

      case store().fetch_job(holder["run_id"]) do
        {:ok, %{"status" => status} = job} when status in @terminal ->
          unless recovering?(job) do
            with :ok <- JobCleanup.cleanup_sandboxes(holder["run_id"], job, []),
                 :ok <- drain_terminal_requests(holder),
                 {:ok, _} <- mutate("release", Map.take(holder, ["run_id", "generation"])) do
              wake()
            else
              _ -> mutate("cleanup_pending", Map.take(holder, ["run_id", "generation"]))
            end
          end

        {:error, reason} when reason == :not_found or reason == missing ->
          # No worker dispatch precedes the durable execution record. The start
          # gate proves that an interrupted uncommitted claim is safe to retire.
          if holder["committed"] == false,
            do: mutate("release", Map.take(holder, ["run_id", "generation"])),
            else: mutate("cleanup_pending", Map.take(holder, ["run_id", "generation"]))

        _ ->
          :ok
      end
    end)
  end

  # Workers have stopped and model unload/reference cleanup succeeded before this
  # proof is requested. A live native reader still prevents release. Lost tokens
  # after a native restart can be retired only at this terminal cleanup boundary.
  defp drain_terminal_requests(holder) do
    with {:ok, state} <- snapshot() do
      tokens = for {token, run} <- state["requests"], run == holder["run_id"], do: token

      if tokens == [] do
        :ok
      else
        with {:ok, %{"status" => "drained"}} <-
               MirrorNeuron.ModelServices.native_resource_command(%{
                 "operation" => "drain_terminal_requests",
                 "run_id" => holder["run_id"],
                 "tokens" => tokens
               }) do
          Enum.reduce_while(tokens, :ok, fn token, :ok ->
            case mutate("request_release", %{"token" => token}) do
              {:ok, _} -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
      end
    end
  end

  defp recovering?(job) do
    job["status"] == "failed" and
      (job["recovery_hint"] == "runner_interruption" or
         (get_in(job, ["result", "agent_id"]) == "job_runner" and
            get_in(job, ["result", "error"]) == "job coordinator exited before terminal state"))
  end

  defp cleanup_legacy(id) do
    case store().fetch_job(id) do
      {:ok, %{"status" => status} = job} when status in @terminal ->
        with :ok <- JobCleanup.cleanup_sandboxes(id, job, []),
             {:ok, _} <- mutate("release_legacy", %{"run_id" => id}),
             do: :ok

      _ ->
        :ok
    end
  end

  defp import_existing do
    with {:ok, jobs} <- store().list_jobs() do
      runs = for job <- jobs, job["status"] in @active, local_run?(job), do: job["job_id"]

      case mutate("import", %{"runs" => runs}) do
        {:ok, _} ->
          # A crash after persisting the request but before queue CAS must not
          # strand an accepted idempotency identity across owner restart.
          jobs
          |> Enum.filter(&(&1["status"] == "queued" and local_run?(&1)))
          |> Enum.sort_by(& &1["submitted_at"])
          |> Enum.reduce_while(:ok, fn job, :ok ->
            case with({:ok, queued_entry} <- entry(job), do: mutate("submit", queued_entry)) do
              {:ok, _} -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)

        error ->
          error
      end
    end
  end

  defp local_run?(job) do
    get_in(job, ["admission", "owner_node"]) == node_name() or
      get_in(job, ["manifest", "metadata", "node_admission", "owner_node"]) == node_name() or
      Enum.any?(get_in(job, ["scheduler", "placements"]) || [], &(&1["node"] == node_name()))
  end

  defp persist_queue_schedule(job) do
    id = "queue_" <> job["job_id"]

    with {:ok, state} <- snapshot() do
      receipt = NodeAdmissionState.receipt(state, job["job_id"])

      schedule = %{
        "kind" => "resource_wait",
        "enabled" => true,
        "status" => "active",
        "target_run_id" => job["job_id"],
        "job_id" => job["stable_job_id"],
        "owner_node" => node_name(),
        "name" => job["job_name"],
        "not_before" => receipt["not_before"],
        "next_run_at" =>
          receipt["not_before"] || job["submitted_at"] || MirrorNeuron.Runtime.timestamp(),
        "retry_interval_ms" => 5_000
      }

      case store().fetch_schedule(id) do
        {:ok, existing} ->
          if existing["not_before"] == schedule["not_before"],
            do: {:ok, existing},
            else: store().persist_schedule(id, Map.merge(existing, schedule))

        _ ->
          store().persist_schedule(id, schedule)
      end
    end
  end

  defp mutate(operation, attrs, attempts \\ 50)
  defp mutate(_operation, _attrs, 0), do: {:error, :node_admission_busy}

  defp mutate(operation, attrs, attempts) do
    attrs =
      Map.put(
        attrs,
        "capacity",
        ResourceAllocation.capacity(Hardware.info(), MirrorNeuron.Resource.limits())
      )

    with {:ok, state} <- snapshot(),
         {:ok, next, result} <- NodeAdmissionState.transition(state, operation, attrs) do
      if next == state do
        {:ok, result}
      else
        case store().compare_node_admission(
               node_name(),
               state["version"],
               Map.put(next, "version", state["version"] + 1)
             ) do
          :ok -> {:ok, result}
          {:error, :admission_conflict} -> mutate(operation, attrs, attempts - 1)
          error -> error
        end
      end
    end
  end

  defp store, do: Application.get_env(:mirror_neuron, :node_admission_store, RedisStore)
end
