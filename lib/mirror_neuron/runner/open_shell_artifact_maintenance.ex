defmodule MirrorNeuron.Runner.OpenShellArtifactMaintenance do
  @moduledoc "Reconciles owner receipts and retries post-commit sandbox cleanup."
  use GenServer
  require Logger
  alias MirrorNeuron.Runner.{OpenShellArtifactStore, OpenShellArtifactHandoff}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(opts) do
    send(self(), :reconcile)
    {:ok, opts}
  end

  def handle_info(:reconcile, state) do
    root = MirrorNeuron.Config.string("MN_SHARED_STORAGE_ROOT", :shared_storage_root)

    Path.wildcard(Path.join(root, "**/.handoff/transactions/*/state.json"), match_dot: true)
    |> Enum.each(&reconcile/1)

    Process.send_after(self(), :reconcile, 60_000)
    {:noreply, state}
  end

  defp reconcile(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, state} <- Jason.decode(bytes),
         true <- get_in(state, ["producer", "owner_node"]) == to_string(node()),
         true <-
           is_binary(state["commit_id"]) and String.match?(state["commit_id"], ~r/^[0-9a-f]{64}$/),
         true <- state["workspace"] == "/sandbox/job/artifact-attempts/" <> state["commit_id"] do
      root = path |> Path.dirname() |> Path.dirname() |> Path.dirname()

      base = %{
        "root" => root,
        "identity" => Map.put(state["producer"], "lease_epoch", state["fence"])
      }

      case OpenShellArtifactStore.call(base, "reconcile") do
        {:ok, %{"phase" => "committed", "cleanup_pending" => true} = recovered} ->
          case OpenShellArtifactHandoff.cleanup(base, recovered, %{}) do
            {:ok, %{"cleanup_pending" => true}} ->
              Logger.warning(
                "OpenShell artifact cleanup pending for commit #{state["commit_id"]}"
              )

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> Logger.warning("OpenShell artifact maintenance could not reconcile an owner transaction")
  end
end
