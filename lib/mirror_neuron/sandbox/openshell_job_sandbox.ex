defmodule MirrorNeuron.Sandbox.OpenShellJobSandbox do
  alias MirrorNeuron.Config
  use GenServer
  require Logger

  @registry MirrorNeuron.Sandbox.Registry
  @supervisor MirrorNeuron.Sandbox.JobSandboxSupervisor

  def child_spec({job_id, config}) do
    %{
      id: {:openshell_job_sandbox, job_id},
      start: {__MODULE__, :start_link, [{job_id, config}]},
      restart: :temporary
    }
  end

  def start_link({job_id, config}) do
    GenServer.start_link(__MODULE__, {job_id, config}, name: via(job_id))
  end

  def ensure(job_id, config) do
    if native_sandbox_prep_enabled?() do
      with {:ok, pid} <- ensure_process(job_id, config) do
        GenServer.call(pid, {:ensure, config}, :infinity)
      end
    else
      prepared_sandbox(job_id, config)
    end
  end

  def cleanup_job_local(job_id, config \\ %{}) do
    if native_sandbox_prep_enabled?() do
      case if(Process.whereis(@registry), do: Registry.lookup(@registry, job_id), else: []) do
        [{pid, _meta}] ->
          cleanup_process(pid)

        [] ->
          cleanup_sandbox_by_job_id(job_id, config)
      end
    else
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
       ready?: false,
       cleanup_required?: false
     }}
  end

  @impl true
  def handle_call({:ensure, config}, _from, state) do
    state = %{state | config: Map.merge(state.config, config), executable: sandbox_cli(config)}

    case ensure_sandbox(state) do
      {:ok, next_state} ->
        next_state = %{next_state | cleanup_required?: true}

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

  def handle_call(:cleanup, _from, state) do
    case cleanup_active_sandbox(state) do
      :ok ->
        {:stop, :normal, :ok, %{state | ready?: false, cleanup_required?: false}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    case delete_sandbox(state.executable, state.sandbox_name,
           allow_missing?: not state.cleanup_required?
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to delete shared sandbox #{state.sandbox_name} for #{state.job_id}: #{inspect(reason)}"
        )
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

  defp cleanup_process(pid) do
    monitor = Process.monitor(pid)

    try do
      case GenServer.call(pid, :cleanup, :infinity) do
        :ok ->
          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
          after
            5_000 ->
              Process.demonitor(monitor, [:flush])
              {:error, :sandbox_owner_stop_timeout}
          end

        {:error, _reason} = error ->
          Process.demonitor(monitor, [:flush])
          error
      end
    catch
      :exit, reason ->
        Process.demonitor(monitor, [:flush])
        {:error, {:sandbox_owner_exit, reason}}
    end
  end

  defp cleanup_sandbox_by_job_id(job_id, config) do
    exact_result =
      delete_sandbox(sandbox_cli(config), build_shared_sandbox_name(job_id, config),
        allow_missing?: true
      )

    job_result = delete_local_docker_job_sandboxes(job_id, config)

    combine_cleanup_results(exact_result, job_result)
  end

  defp cleanup_active_sandbox(state) do
    exact_result =
      delete_sandbox(state.executable, state.sandbox_name,
        allow_missing?: not state.cleanup_required?
      )

    job_result = delete_local_docker_job_sandboxes(state.job_id, state.config)
    combine_cleanup_results(exact_result, job_result)
  end

  defp combine_cleanup_results(exact_result, job_result) do
    case {exact_result, job_result} do
      {{:error, reason}, {:error, docker_reason}} ->
        {:error, %{"sandbox" => reason, "job_docker" => docker_reason}}

      {{:error, reason}, _job_result} ->
        {:error, reason}

      {:ok, {:error, reason}} ->
        {:error, %{"job_docker" => reason}}

      {:ok, _job_result} ->
        :ok
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

  defp delete_sandbox(executable, sandbox_name, opts) do
    allow_missing? = Keyword.get(opts, :allow_missing?, false)
    openshell_result = delete_openshell_sandbox(executable, sandbox_name)
    docker_result = delete_local_docker_sandbox(sandbox_name)

    case {openshell_result, docker_result} do
      {:ok, {:error, reason}} ->
        {:error, %{"openshell" => "deleted", "docker" => reason}}

      {:ok, _docker_result} ->
        :ok

      {{:error, _reason}, :removed} ->
        :ok

      {{:error, _reason}, docker_result}
      when allow_missing? and docker_result in [:missing, :unavailable] ->
        :ok

      {{:error, reason}, docker_result} ->
        {:error, cleanup_error(reason, docker_result)}
    end
  end

  defp delete_openshell_sandbox(executable, sandbox_name) do
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

  defp delete_local_docker_sandbox(sandbox_name) do
    delete_local_docker_containers("openshell-#{sandbox_name}")
  end

  defp delete_local_docker_job_sandboxes(job_id, config) do
    delete_local_docker_containers(openshell_job_container_prefix(job_id, config))
  end

  defp delete_local_docker_containers(container_name_prefix) do
    case docker_cli() do
      nil ->
        :unavailable

      docker ->
        case local_docker_container_ids(docker, container_name_prefix) do
          {:ok, []} ->
            :missing

          {:ok, ids} ->
            case System.cmd(docker, ["rm", "-f" | ids], stderr_to_stdout: true) do
              {_output, 0} -> :removed
              {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    error in ErlangError ->
      {:error, Exception.message(error)}
  end

  defp local_docker_container_ids(docker, container_name_prefix) do
    case System.cmd(
           docker,
           [
             "ps",
             "-a",
             "--filter",
             "name=#{container_name_prefix}",
             "--format",
             "{{.ID}}\t{{.Names}}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        ids =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "\t", parts: 2) do
              [id, name] ->
                if openshell_container_name?(name, container_name_prefix), do: [id], else: []

              _other ->
                []
            end
          end)

        {:ok, ids}

      {output, exit_code} ->
        {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  end

  defp openshell_container_name?(name, container_name_prefix) do
    name == container_name_prefix or String.starts_with?(name, "#{container_name_prefix}-")
  end

  defp openshell_job_container_prefix(job_id, config) do
    prefix = Map.get(config, "shared_sandbox_prefix", "mirror-neuron-job")

    base =
      [prefix, job_id]
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    "openshell-#{base}"
  end

  defp docker_cli do
    case MirrorNeuron.Config.optional_string("MN_DOCKER_BIN", :docker_bin) do
      value when is_binary(value) and value != "" -> value
      _ -> System.find_executable("docker")
    end
  end

  defp cleanup_error(openshell_reason, docker_result) do
    docker_reason =
      case docker_result do
        :missing -> "no matching local Docker container"
        :unavailable -> "docker executable not available"
        {:error, reason} -> reason
      end

    %{"openshell" => openshell_reason, "docker" => docker_reason}
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
    Map.get(
      config,
      "sandbox_cli",
      Config.executable("MN_OPENSHELL_BIN", :openshell_bin)
    )
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

  defp prepared_sandbox(job_id, config) do
    sandbox_name =
      Map.get(config, "sandbox_name") ||
        Map.get(config, "openshell_sandbox_name") ||
        System.get_env("MN_OPENSHELL_SANDBOX_NAME")

    ssh_host =
      Map.get(config, "ssh_host") ||
        Map.get(config, "openshell_ssh_host") ||
        System.get_env("MN_OPENSHELL_SSH_HOST")

    cond do
      is_binary(sandbox_name) and sandbox_name != "" ->
        {:ok,
         %{
           "sandbox_name" => sandbox_name,
           "ssh_host" => ssh_host || ssh_host(sandbox_name)
         }}

      true ->
        {:error,
         "OpenShell sandbox for job #{job_id} is not prepared; prepare OpenShell resources with mn-python-sdk/API/CLI and provide sandbox_name or MN_OPENSHELL_SANDBOX_NAME"}
    end
  end

  defp native_sandbox_prep_enabled? do
    System.get_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
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
