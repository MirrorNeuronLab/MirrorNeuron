defmodule MirrorNeuron.Sandbox.JobSandbox do
  alias MirrorNeuron.Config
  use GenServer
  require Logger

  @registry MirrorNeuron.Sandbox.Registry
  @supervisor MirrorNeuron.Sandbox.JobSandboxSupervisor

  def child_spec({job_id, config}) do
    %{
      id: {:job_sandbox, job_id},
      start: {__MODULE__, :start_link, [{job_id, config}]},
      restart: :temporary
    }
  end

  def start_link({job_id, config}) do
    GenServer.start_link(__MODULE__, {job_id, config}, name: via(job_id))
  end

  def ensure(job_id, config) do
    with {:ok, pid} <- ensure_process(job_id, config) do
      GenServer.call(pid, {:ensure, config}, :infinity)
    end
  end

  def cleanup_job_local(job_id) do
    case Registry.lookup(@registry, job_id) do
      [{pid, _meta}] ->
        GenServer.stop(pid, :normal, :infinity)
        :ok

      [] ->
        :ok
    end
  end

  @impl true
  def init({job_id, config}) do
    {:ok,
     %{
       job_id: job_id,
       config: config,
       executable: sandbox_cli(config),
       sandbox_name: build_shared_sandbox_name(job_id, config),
       ready?: false
     }}
  end

  @impl true
  def handle_call({:ensure, config}, _from, state) do
    state = %{state | config: Map.merge(state.config, config), executable: sandbox_cli(config)}

    case ensure_sandbox(state) do
      {:ok, next_state} ->
        {:reply,
         {:ok,
          %{
            "sandbox_name" => next_state.sandbox_name,
            "ssh_host" => ssh_host(next_state.sandbox_name)
          }}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.ready? do
      case delete_sandbox(state.executable, state.sandbox_name) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "failed to delete shared sandbox #{state.sandbox_name} for #{state.job_id}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp ensure_process(job_id, config) do
    case Registry.lookup(@registry, job_id) do
      [{pid, _meta}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {job_id, config}}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ensure_sandbox(%{ready?: true} = state), do: {:ok, state}

  defp ensure_sandbox(state) do
    cond do
      sandbox_exists?(state.executable, state.sandbox_name) ->
        {:ok, %{state | ready?: true}}

      true ->
        case create_sandbox(state.executable, state.sandbox_name, state.config) do
          :ok ->
            {:ok, %{state | ready?: true}}

          {:error, reason} ->
            if sandbox_exists?(state.executable, state.sandbox_name) do
              {:ok, %{state | ready?: true}}
            else
              {:error, reason}
            end
        end
    end
  end

  defp create_sandbox(executable, sandbox_name, config) do
    args =
      [
        "sandbox",
        "create",
        "--name",
        sandbox_name
      ]
      |> maybe_put_flag("--gpu", Map.get(config, "gpu", false))
      |> maybe_put_value("--from", Map.get(config, "from"))
      |> maybe_put_value("--remote", Map.get(config, "remote"))
      |> maybe_put_value("--ssh-key", Map.get(config, "ssh_key"))
      |> maybe_put_value("--policy", Map.get(config, "policy"))
      |> maybe_put_many("--provider", Map.get(config, "providers", []))
      |> maybe_put_tty(Map.get(config, "tty"))
      |> maybe_put_flag("--no-auto-providers", Map.get(config, "no_auto_providers", true))
      |> Kernel.++(["--", "bash", "-lc", "mkdir -p /sandbox/job && true"])

    case System.cmd(executable, args, stderr_to_stdout: true, env: [{"NO_COLOR", "1"}]) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        {:error,
         %{
           "error" => "failed to create shared sandbox",
           "exit_code" => exit_code,
           "logs" => output
         }}
    end
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  defp delete_sandbox(executable, sandbox_name) do
    case System.cmd(executable, ["sandbox", "delete", sandbox_name],
           stderr_to_stdout: true,
           env: [{"NO_COLOR", "1"}]
         ) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError ->
      {:error, Exception.message(error)}
  end

  defp sandbox_exists?(executable, sandbox_name) do
    case System.cmd(executable, ["sandbox", "get", sandbox_name],
           stderr_to_stdout: true,
           env: [{"NO_COLOR", "1"}]
         ) do
      {_output, 0} -> true
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp via(job_id), do: {:via, Registry, {@registry, job_id}}

  defp ssh_host(sandbox_name), do: "openshell-#{sandbox_name}"

  defp sandbox_cli(config) do
    Map.get(config, "sandbox_cli", Config.string("MIRROR_NEURON_OPENSHELL_BIN", :openshell_bin))
  end

  defp build_shared_sandbox_name(job_id, config) do
    prefix = Map.get(config, "shared_sandbox_prefix", "mirror-neuron-job")

    node_tag =
      Node.self()
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9]/, "-")

    digest =
      :crypto.hash(:sha256, "#{prefix}:#{job_id}:#{node_tag}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    base =
      [prefix, job_id, node_tag]
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    suffix = "-#{digest}"
    keep = max(63 - String.length(suffix), 1)
    String.slice(base, 0, keep) <> suffix
  end

  defp maybe_put_flag(args, _flag, false), do: args
  defp maybe_put_flag(args, flag, true), do: args ++ [flag]

  defp maybe_put_value(args, _flag, nil), do: args
  defp maybe_put_value(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_put_many(args, _flag, values) when values in [nil, []], do: args

  defp maybe_put_many(args, flag, values) do
    Enum.reduce(values, args, fn value, acc -> acc ++ [flag, to_string(value)] end)
  end

  defp maybe_put_tty(args, true), do: args ++ ["--tty"]
  defp maybe_put_tty(args, false), do: args ++ ["--no-tty"]
  defp maybe_put_tty(args, nil), do: args
end
