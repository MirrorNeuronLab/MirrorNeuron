defmodule MirrorNeuron.Runtime.RunControl do
  @moduledoc "Durable ordered lifecycle commands; runner details remain behind adapters."
  alias MirrorNeuron.Persistence.{RedisStore, RunControlStore}

  def submit(run_id, action, request_id \\ "", queued_only \\ false) do
    id =
      if request_id == "",
        do: "control-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        else: request_id

    with true <-
           action in ~w(pause resume cancel) and is_binary(id) and byte_size(id) in 1..128 and
             is_boolean(queued_only) and (not queued_only or action == "cancel"),
         {:ok, _} <- RedisStore.fetch_job(run_id),
         {:ok, receipt} <- RunControlStore.enqueue(run_id, action, id, queued_only) do
      wake(run_id)
      {:ok, receipt}
    else
      false -> {:error, :invalid_run_control}
      error -> error
    end
  end

  def get(run_id, request_id) when is_binary(request_id) and byte_size(request_id) in 1..128,
    do: RunControlStore.get(run_id, request_id)

  def get(_, _), do: {:error, :invalid_run_control}

  def wake(run_id) do
    case DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__.Driver, run_id}) do
      {:ok, pid} -> send(pid, :advance)
      {:error, {:already_started, pid}} -> send(pid, :advance)
      _ -> :ok
    end

    :ok
  end
end

defmodule MirrorNeuron.Runtime.RunControl.Reconciler do
  @moduledoc false
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, nil, {:continue, :recover}}
  def handle_continue(:recover, state), do: handle_info(:recover, state)

  def handle_info(:recover, state) do
    case MirrorNeuron.Persistence.RunControlStore.pending() do
      {:ok, runs} -> Enum.each(runs, &MirrorNeuron.Runtime.RunControl.wake/1)
      _ -> :ok
    end

    Process.send_after(self(), :recover, 5_000)
    {:noreply, state}
  end
end
