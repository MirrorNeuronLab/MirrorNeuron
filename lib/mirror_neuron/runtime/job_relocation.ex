defmodule MirrorNeuron.Runtime.JobRelocation do
  @moduledoc "Recoverable ownership transfer for idle durable jobs."
  alias MirrorNeuron.Cluster.{FederationClient, NodeAdapter}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{JobResponse, NodeAdmission, RunnerResources, StableJob}
  alias Mirrorneuron.Job.V1.JobRelocationRequest

  @terminal ~w(completed failed cancelled)

  def command(%{action: "inspect", job_id: id}), do: inspect_local(id)

  def command(%{action: "abort", job_id: id}) do
    StableJob.with_start_gate(id, fn ->
      with {:ok, definition} <- StableJob.get(id),
           true <- definition["status"] == "relocating",
           {:ok, saved} <- save(definition, "active", "aborted") do
        _ = JobResponse.definition_changed(saved)
        {:ok, summary(saved)}
      else
        false -> {:error, :relocation_already_committed}
        error -> error
      end
    end)
  end

  def command(%{action: "move"} = request) do
    with :ok <- valid_request(request),
         {:ok, journal} <- freeze(request),
         request <- %{
           request
           | transfer_id: journal["transfer_id"],
             source_node: journal["source_node"]
         },
         {:ok, staged} <- peer(journal["target_node"], "stage", request, journal),
         :ok <- stage_proven(staged, request),
         {:ok, journal} <- commit(request.job_id, journal),
         {:ok, activated} <- peer(journal["target_node"], "activate", request, journal),
         :ok <- activation_proven(activated, request) do
      # Definition resources are retired only after destination activation is
      # proven. Data/history stay as a recovery copy and are never GC'd as RAM.
      cleanup = cleanup_source(request.job_id, journal)
      finish(request.job_id, journal, cleanup)
    end
  end

  def command(%{action: "stage"} = request) do
    with :ok <- valid_request(request) do
      StableJob.with_start_gate(
        "relocation_stage_" <> Base.encode16(:crypto.hash(:sha256, request.job_id), case: :lower),
        fn -> stage(request) end
      )
    end
  end

  def command(%{action: "activate"} = request) do
    with :ok <- valid_request(request),
         true <- request.target_node == local(),
         {:ok, source} <- peer(request.source_node, "inspect", request, %{}),
         true <- source["status"] == "relocated",
         true <- matching?(source["relocation"], request),
         true <- source["owner_node"] == local() do
      StableJob.with_start_gate(request.job_id, fn ->
        with {:ok, destination} <- StableJob.get(request.job_id),
             true <- matching?(destination["relocation"], request),
             true <- destination["status"] in ["relocation_staged", "active"],
             {:ok, saved} <- save(destination, "active", "active") do
          _ = JobResponse.definition_changed(saved)
          {:ok, summary(saved)}
        else
          false -> {:error, :invalid_relocation_state}
          error -> error
        end
      end)
    else
      false -> {:error, :invalid_relocation_state}
      error -> error
    end
  end

  def command(_), do: {:error, :invalid_relocation_request}

  defp cleanup_source(job_id, journal) do
    retired = %{
      "metadata" => %{
        "mn_native_resources" => %{"resources" => journal["source_resources"] || []}
      }
    }

    with :ok <- RunnerResources.cleanup_retired_native_resources(retired, %{}) do
      Enum.reduce_while(journal["source_schedule_ids"] || [], :ok, fn id, :ok ->
        missing = "schedule #{id} was not found"

        case RedisStore.fetch_schedule(id) do
          {:ok, %{"job_id" => ^job_id, "enabled" => false}} ->
            case RedisStore.delete_schedule(id) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end

          {:error, ^missing} ->
            {:cont, :ok}

          _ ->
            {:halt, {:error, :relocation_schedule_cleanup_pending}}
        end
      end)
    end
  end

  defp stage_proven(%{"status" => status, "job_id" => id, "relocation" => journal}, request)
       when status in ["relocation_staged", "active"] do
    if id == request.job_id and matching?(journal, request) and
         journal["phase"] == if(status == "active", do: "active", else: "staged"),
       do: :ok,
       else: {:error, :invalid_relocation_state}
  end

  defp stage_proven(_, _), do: {:error, :invalid_relocation_state}

  defp activation_proven(%{"status" => "active", "owner_node" => owner} = receipt, request) do
    if owner == request.target_node,
      do: stage_proven(receipt, request),
      else: {:error, :invalid_relocation_state}
  end

  defp activation_proven(_, _), do: {:error, :invalid_relocation_state}

  defp stage(request) do
    with :ok <- valid_request(request),
         true <- request.target_node == local(),
         {:ok, source} <- peer(request.source_node, "inspect", request, %{}),
         true <- matching?(source["relocation"], request),
         true <- source["status"] in ["relocating", "relocated"] do
      missing = "job #{request.job_id} was not found"

      case StableJob.get(request.job_id) do
        {:ok, destination} ->
          cond do
            matching?(destination["relocation"], request) ->
              prepare_destination(request, source["relocation"], destination)

            replaceable_destination?(destination, source["relocation"]) ->
              prepare_destination(request, source["relocation"], nil)

            true ->
              {:error, :job_already_exists}
          end

        {:error, ^missing} ->
          prepare_destination(request, source["relocation"], nil)

        error ->
          error
      end
    else
      false -> {:error, :invalid_relocation_state}
      error -> error
    end
  end

  defp prepare_destination(_request, _journal, %{"status" => "active"} = destination),
    do: {:ok, summary(destination)}

  defp prepare_destination(request, journal, existing) do
    existing =
      if existing && get_in(existing, ["relocation", "phase"]) == "receiving" do
        {:ok, finalized} = MirrorNeuron.Backup.RelocationRestore.finalize(existing)
        finalized
      else
        existing
      end

    attrs = %{
      "operation" => "stage_job_relocation",
      "job_id" => request.job_id,
      "relocation" => journal
    }

    attrs =
      if existing,
        do: Map.put(attrs, "prepared_manifest_json", Jason.encode!(existing["manifest"])),
        else: attrs

    MirrorNeuron.ModelServices.native_resource_command(attrs, 600_000)
  end

  def inspect_local(id) do
    with {:ok, definition} <- StableJob.get(id), do: {:ok, summary(definition)}
  end

  def reconcile_cleanup do
    with {:ok, definitions} <- RedisStore.list_job_definitions() do
      definitions
      |> Enum.filter(
        &(&1["status"] == "relocated" and
            get_in(&1, ["relocation", "phase"]) in ["committed", "cleanup_pending"])
      )
      |> Enum.each(fn definition ->
        journal = definition["relocation"]

        command(
          struct(JobRelocationRequest, %{
            job_id: definition["job_id"],
            action: "move",
            source_node: journal["source_node"],
            target_node: journal["target_node"],
            transfer_id: journal["transfer_id"],
            version: 1
          })
        )
      end)
    end
  end

  defp freeze(request) do
    StableJob.with_start_gate(request.job_id, fn ->
      with {:ok, definition} <- StableJob.get(request.job_id) do
        cond do
          matching?(definition["relocation"], request) ->
            finish_freeze(definition)

          definition["status"] in ["relocating", "relocated"] and
              get_in(definition, ["relocation", "target_node"]) == request.target_node ->
            finish_freeze(definition)

          request.target_node == local() ->
            {:error, :relocation_target_is_owner}

          definition["status"] != "active" ->
            {:error, :job_not_active}

          true ->
            with {:ok, runs} <- StableJob.list_runs(request.job_id),
                 true <- Enum.all?(runs, &(&1["status"] in @terminal)),
                 :ok <- no_claims(runs),
                 :ok <- paused_schedules(definition),
                 :ok <- portable(definition) do
              journal = %{
                "transfer_id" => request.transfer_id,
                "source_node" => local(),
                "target_node" => request.target_node,
                "phase" => "freezing",
                "source_data_generation" => definition["data_generation"] || 1,
                "source_schedule_ids" => definition["schedule_ids"] || [],
                "source_resources" =>
                  (get_in(definition, ["manifest", "metadata", "mn_native_resources", "resources"]) ||
                     [])
                  |> Enum.map(&Map.take(&1, ~w(kind external_id owner_node submission_id scope))),
                "started_at" => MirrorNeuron.Runtime.timestamp()
              }

              with {:ok, frozen} <-
                     save(Map.put(definition, "relocation", journal), "relocating", "freezing"),
                   do: finish_freeze(frozen)
            else
              false -> {:error, :relocation_requires_idle_job}
              error -> error
            end
        end
      end
    end)
  end

  defp finish_freeze(
         %{"status" => "relocating", "relocation" => %{"phase" => "freezing"}} = definition
       ) do
    # Persist the write fence before draining Chat; a new turn cannot slip in
    # between a successful native stop and the durable source freeze.
    with :ok <- JobResponse.stop(definition),
         {:ok, saved} <- save(definition, "relocating", "frozen"),
         do: {:ok, saved["relocation"]}
  end

  defp finish_freeze(definition), do: {:ok, definition["relocation"]}

  defp no_claims(runs) do
    with {:ok, state} <- NodeAdmission.snapshot() do
      ids = MapSet.new(Enum.map(runs, & &1["run_id"]))

      busy =
        Enum.any?(Map.keys(state["reservations"]) ++ state["legacy"], &MapSet.member?(ids, &1))

      if busy, do: {:error, :relocation_cleanup_pending}, else: :ok
    end
  end

  defp paused_schedules(definition) do
    Enum.reduce_while(definition["schedule_ids"] || [], :ok, fn id, :ok ->
      case RedisStore.fetch_schedule(id) do
        {:ok, %{"enabled" => false}} -> {:cont, :ok}
        _ -> {:halt, {:error, :pause_schedules_before_relocation}}
      end
    end)
  end

  defp portable(definition) do
    manifest = definition["manifest"] || %{}
    nodes = manifest["nodes"] || get_in(manifest, ["flow", "nodes"]) || []
    local_only = get_in(manifest, ["policies", "must_run_local"]) == true

    writable_host =
      Enum.any?(nodes, fn node ->
        Enum.any?(get_in(node, ["resources", "volumes"]) || [], &(&1["mode"] != "ro"))
      end)

    if local_only or writable_host, do: {:error, :relocation_requires_portable_storage}, else: :ok
  end

  defp commit(id, journal) do
    StableJob.with_start_gate(id, fn ->
      with {:ok, definition} <- StableJob.get(id),
           true <- definition["relocation"]["transfer_id"] == journal["transfer_id"],
           true <- definition["status"] in ["relocating", "relocated"],
           {:ok, saved} <-
             save(
               Map.put(definition, "owner_node", journal["target_node"]),
               "relocated",
               "committed"
             ) do
        {:ok, saved["relocation"]}
      else
        false -> {:error, :invalid_relocation_state}
        error -> error
      end
    end)
  end

  defp finish(id, journal, cleanup) do
    StableJob.with_start_gate(id, fn ->
      with {:ok, definition} <- StableJob.get(id),
           true <- definition["relocation"]["transfer_id"] == journal["transfer_id"],
           {:ok, saved} <-
             save(
               definition,
               "relocated",
               if(cleanup == :ok, do: "completed", else: "cleanup_pending")
             ) do
        {:ok, summary(saved)}
      end
    end)
  end

  # The source attests the immutable user data and evidence independently of the
  # destination's rewritten executable paths and native resource preparation.
  def data_digest(inventory) do
    inventory
    |> Enum.filter(fn {name, _} ->
      Enum.any?(
        ~w(job-data history artifacts),
        &(name == &1 or String.starts_with?(name, &1 <> "/"))
      )
    end)
    |> Enum.map(fn {name, item} -> [name, item["sha256"], item["size"], item["directory"]] end)
    |> Enum.sort()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def attest_export(definition, inventory) do
    if definition["status"] == "relocating" do
      if get_in(definition, ["relocation", "phase"]) != "frozen",
        do: raise(ArgumentError, "source response service has not drained")

      journal = Map.put(definition["relocation"], "data_sha256", data_digest(inventory))

      {:ok, saved} =
        RedisStore.persist_job_definition(
          definition["job_id"],
          Map.put(definition, "relocation", journal)
        )

      saved
    else
      definition
    end
  end

  def verify_restore(job_id, relocation, inventory) do
    request =
      struct(JobRelocationRequest, %{
        job_id: job_id,
        transfer_id: relocation["transfer_id"],
        source_node: relocation["source_node"],
        target_node: relocation["target_node"],
        version: 1
      })

    with :ok <- valid_request(request),
         true <- request.target_node == local(),
         {:ok, source} <- peer(request.source_node, "inspect", request, %{}),
         true <- source["status"] == "relocating",
         true <- get_in(source, ["relocation", "phase"]) == "frozen",
         true <- matching?(source["relocation"], request),
         true <- source["relocation"]["data_sha256"] == data_digest(inventory) do
      receiving_journal(job_id, source["relocation"])
    else
      _ -> {:error, :relocation_verification_failed}
    end
  end

  @doc false
  def replaceable_destination?(destination, journal) do
    source = journal["source_node"]

    (destination["status"] == "relocated" and destination["owner_node"] == source and
       get_in(destination, ["relocation", "target_node"]) == source and
       get_in(destination, ["relocation", "phase"]) == "completed") or
      (destination["status"] == "relocation_staged" and
         get_in(destination, ["relocation", "source_node"]) == source and
         get_in(destination, ["relocation", "transfer_id"]) != journal["transfer_id"])
  end

  defp receiving_journal(id, journal) do
    missing = "job #{id} was not found"

    case StableJob.get(id) do
      {:error, ^missing} ->
        {:ok, Map.put(journal, "phase", "receiving")}

      {:ok, previous} ->
        if replaceable_destination?(previous, journal) do
          {:ok,
           journal
           |> Map.put("phase", "receiving")
           |> Map.put("replaces_revision", previous["revision"])
           |> Map.put("retired_schedule_ids", previous["schedule_ids"] || [])}
        else
          {:error, :job_already_exists}
        end

      error ->
        error
    end
  end

  defp peer(node, action, request, journal) do
    remote = %{
      request
      | action: action,
        source_node: journal["source_node"] || request.source_node,
        target_node: journal["target_node"] || request.target_node
    }

    FederationClient.call(node, :relocate_job, remote) |> decode_peer_receipt()
  end

  @doc false
  def decode_peer_receipt(%Mirrorneuron.Job.V1.JsonResponse{result_json: json}) do
    case Jason.decode(json) do
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      _ -> {:error, :invalid_relocation_state}
    end
  end

  def decode_peer_receipt(_), do: {:error, :invalid_relocation_state}

  defp matching?(journal, request) when is_map(journal),
    do:
      journal["transfer_id"] == request.transfer_id and
        journal["target_node"] == request.target_node and
        (request.source_node == "" or journal["source_node"] == request.source_node)

  defp matching?(_, _), do: false

  defp valid_request(request) do
    if MirrorNeuron.JobData.validate_id(request.job_id) == :ok and
         Regex.match?(~r/\A[a-f0-9]{32}\z/, request.transfer_id) and
         is_binary(request.target_node) and byte_size(request.target_node) in 1..255,
       do: :ok,
       else: {:error, :invalid_relocation_request}
  end

  defp save(definition, status, phase) do
    updated =
      definition
      |> Map.put("status", status)
      |> Map.update!("relocation", &Map.put(&1, "phase", phase))
      |> Map.update!("revision", &(&1 + 1))
      |> Map.put("updated_at", MirrorNeuron.Runtime.timestamp())

    RedisStore.persist_job_definition(definition["job_id"], updated)
  end

  defp summary(definition), do: Map.take(definition, ~w(job_id status owner_node relocation))
  defp local, do: to_string(NodeAdapter.self())
end
