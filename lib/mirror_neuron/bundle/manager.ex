defmodule MirrorNeuron.Bundle.Manager do
  @moduledoc """
  Manages registered bundles and their current fingerprints.
  """
  use GenServer
  require Logger

  alias MirrorNeuron.Bundle.{Fingerprint, Source.LocalFilesystem}
  alias MirrorNeuron.JobBundle

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_bundle(bundle_id) do
    GenServer.call(__MODULE__, {:get_bundle, bundle_id})
  end

  def list_bundles do
    GenServer.call(__MODULE__, :list_bundles)
  end

  def reload(bundle_id, trigger_reason \\ "manual") do
    GenServer.call(__MODULE__, {:reload, bundle_id, trigger_reason})
  end

  def register_dir(path) do
    GenServer.cast(__MODULE__, {:register_dir, path})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      # bundle_id => %{path, fingerprint, bundle_struct, last_reloaded}
      bundles: %{},
      dirs: []
    }

    # Automatically load from configured env if present
    if dir = System.get_env("MIRROR_NEURON_BUNDLES_DIR") do
      send(self(), {:scan_dir, dir})
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:get_bundle, bundle_id}, _from, state) do
    {:reply, Map.fetch(state.bundles, bundle_id), state}
  end

  @impl true
  def handle_call(:list_bundles, _from, state) do
    {:reply, Map.values(state.bundles), state}
  end

  @impl true
  def handle_call({:reload, bundle_id, reason}, _from, state) do
    case Map.get(state.bundles, bundle_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      record ->
        path = record.path
        old_fingerprint = record.fingerprint

        case Fingerprint.compute(path) do
          {:ok, new_fingerprint} ->
            if new_fingerprint == old_fingerprint do
              # No change
              resp = %{
                bundle_id: bundle_id,
                changed: false,
                reloaded: false,
                message: "No bundle changes detected"
              }

              {:reply, {:ok, resp}, state}
            else
              # Changed, attempt to load new manifest
              case JobBundle.load(path) do
                {:ok, new_bundle} ->
                  now = DateTime.utc_now() |> DateTime.to_iso8601()

                  new_record = %{
                    record
                    | fingerprint: new_fingerprint,
                      bundle_struct: new_bundle,
                      last_reloaded: now
                  }

                  new_state = %{state | bundles: Map.put(state.bundles, bundle_id, new_record)}

                  Logger.info("Bundle #{bundle_id} reloaded successfully. Reason: #{reason}")

                  resp = %{
                    bundle_id: bundle_id,
                    changed: true,
                    reloaded: true,
                    previous_fingerprint: old_fingerprint,
                    current_fingerprint: new_fingerprint,
                    reason: reason,
                    message: "Bundle reloaded successfully",
                    timestamp: now
                  }

                  {:reply, {:ok, resp}, new_state}

                {:error, err} ->
                  Logger.error("Failed to reload bundle #{bundle_id}: #{inspect(err)}")
                  {:reply, {:error, "Manifest validation failed: #{inspect(err)}"}, state}
              end
            end

          {:error, reason} ->
            {:reply, {:error, "Fingerprint failed: #{inspect(reason)}"}, state}
        end
    end
  end

  @impl true
  def handle_cast({:register_dir, path}, state) do
    send(self(), {:scan_dir, path})
    {:noreply, %{state | dirs: [path | state.dirs]}}
  end

  @impl true
  def handle_info({:scan_dir, dir}, state) do
    bundle_paths = LocalFilesystem.list_bundles(dir)

    new_bundles =
      Enum.reduce(bundle_paths, state.bundles, fn path, acc ->
        case JobBundle.load(path) do
          {:ok, bundle} ->
            bundle_id = bundle.manifest.graph_id

            # Use environment overrides if provided
            mode_env = System.get_env("MIRROR_NEURON_BUNDLE_RELOAD_MODE")
            interval_env = System.get_env("MIRROR_NEURON_BUNDLE_RELOAD_INTERVAL_SECONDS")

            reload_config = bundle.manifest.reload

            mode = mode_env || reload_config.mode

            interval =
              if interval_env do
                String.to_integer(interval_env)
              else
                reload_config.interval_seconds
              end

            # Update manifest config directly for consistency
            updated_manifest = %{
              bundle.manifest
              | reload: %{mode: mode, interval_seconds: interval}
            }

            updated_bundle = %{bundle | manifest: updated_manifest}

            {:ok, fingerprint} = Fingerprint.compute(path)

            record = %{
              bundle_id: bundle_id,
              path: path,
              fingerprint: fingerprint,
              bundle_struct: updated_bundle,
              last_reloaded: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            Map.put_new(acc, bundle_id, record)

          {:error, err} ->
            Logger.warning("Failed to load bundle in dir #{path}: #{inspect(err)}")
            acc
        end
      end)

    {:noreply, %{state | bundles: new_bundles}}
  end
end
