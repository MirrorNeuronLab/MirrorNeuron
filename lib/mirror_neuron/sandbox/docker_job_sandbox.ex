defmodule MirrorNeuron.Sandbox.DockerJobSandbox do
  @moduledoc false

  use GenServer
  require Logger

  alias MirrorNeuron.Artifacts.SharedStorage

  @registry MirrorNeuron.Sandbox.Registry
  @supervisor MirrorNeuron.Sandbox.JobSandboxSupervisor
  @container_root "/mn/job"

  def child_spec({job_id, image, config, opts}) do
    %{
      id: {:docker_job_sandbox, job_id},
      start: {__MODULE__, :start_link, [{job_id, image, config, opts}]},
      restart: :temporary
    }
  end

  def start_link({job_id, image, config, opts}) do
    GenServer.start_link(__MODULE__, {job_id, image, config, opts}, name: via(job_id))
  end

  def ensure(job_id, image, config, opts \\ []) do
    if native_sandbox_prep_enabled?() do
      with {:ok, pid} <- ensure_process(job_id, image, config, opts) do
        GenServer.call(pid, {:ensure, image, config, opts}, :infinity)
      end
    else
      prepared_sandbox(job_id, image, config)
    end
  end

  def cleanup_job_local(job_id, config \\ %{}) do
    if native_sandbox_prep_enabled?() do
      case if(Process.whereis(@registry), do: Registry.lookup(@registry, key(job_id)), else: []) do
        [{pid, _meta}] ->
          GenServer.stop(pid, :normal, :infinity)
          :ok

        [] ->
          cleanup_container_by_job_id(job_id, config)
      end
    else
      :ok
    end
  end

  @impl true
  def init({job_id, image, config, opts}) do
    {:ok,
     %{
       job_id: job_id,
       image: image,
       config: config,
       opts: opts,
       container_name: build_container_name(job_id, config),
       ready?: false
     }}
  end

  @impl true
  def handle_call({:ensure, image, config, opts}, _from, state) do
    cond do
      state.image not in [nil, image] ->
        {:reply,
         {:error,
          "docker worker shared container for job #{state.job_id} already uses image #{state.image}, cannot use #{image}"},
         state}

      true ->
        state = %{state | image: image, config: Map.merge(state.config, config), opts: opts}

        case ensure_container(state) do
          {:ok, next_state} ->
            {:reply,
             {:ok,
              %{
                "container_name" => next_state.container_name,
                "image" => next_state.image,
                "workdir_root" => @container_root
              }}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    case remove_container(state.container_name, state.config, allow_missing?: true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to delete shared DockerWorker container #{state.container_name} for #{state.job_id}: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp ensure_process(job_id, image, config, opts) do
    case Registry.lookup(@registry, key(job_id)) do
      [{pid, _meta}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, {job_id, image, config, opts}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_container(%{ready?: true} = state), do: {:ok, state}

  defp ensure_container(state) do
    cond do
      container_running?(state.container_name, state.config) ->
        {:ok, %{state | ready?: true}}

      container_exists?(state.container_name, state.config) ->
        case docker_cmd(["start", state.container_name], state.config) do
          {:ok, _output} -> {:ok, %{state | ready?: true}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case create_container(state) do
          :ok -> {:ok, %{state | ready?: true}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp create_container(state) do
    args =
      ["run", "-d", "--name", state.container_name]
      |> put_label("mirror-neuron.kind", "docker_worker")
      |> put_label("mirror-neuron.job_id", state.job_id)
      |> put_label("mirror-neuron.image", state.image)
      |> put_network_args(state.config)
      |> put_host_gateway_args(state.config)
      |> put_gpu_args(state.config, state.opts)
      |> put_shared_storage_mount(state.config)
      |> put_allocation_volumes(state.config, state.opts)
      |> Kernel.++([
        "--entrypoint",
        "sh",
        state.image,
        "-lc",
        "mkdir -p #{@container_root} && tail -f /dev/null"
      ])

    case docker_cmd(args, state.config) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        {:error,
         %{"error" => "failed to create shared DockerWorker container", "reason" => reason}}
    end
  end

  defp cleanup_container_by_job_id(job_id, config) do
    container_name = build_container_name(job_id, config)

    case remove_container(container_name, config, allow_missing?: true) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, %{"docker_worker" => reason}}
    end
  end

  defp remove_container(container_name, config, opts) do
    allow_missing? = Keyword.get(opts, :allow_missing?, false)

    case docker_cmd(["rm", "-f", container_name], config) do
      {:ok, _output} ->
        :ok

      {:error, %{"exit_code" => exit_code, "logs" => logs} = reason} ->
        if allow_missing? and exit_code != 0 and missing_container?(logs) do
          :ok
        else
          {:error, reason}
        end
    end
  end

  defp container_running?(container_name, config) do
    case docker_cmd(["inspect", "-f", "{{.State.Running}}", container_name], config) do
      {:ok, output} -> String.trim(output) == "true"
      {:error, _reason} -> false
    end
  end

  defp container_exists?(container_name, config) do
    case docker_cmd(["inspect", container_name], config) do
      {:ok, _output} -> true
      {:error, _reason} -> false
    end
  end

  defp docker_cmd(args, config) do
    docker = docker_bin(config)

    case System.cmd(docker, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError ->
      {:error, Exception.message(error)}
  end

  defp put_label(args, key, value), do: args ++ ["--label", "#{key}=#{value}"]

  defp put_network_args(args, config) do
    docker = Map.get(config, "docker", %{})

    network =
      Map.get(docker, "network") ||
        Map.get(config, "network") ||
        MirrorNeuron.Config.optional_string("MN_DOCKER_WORKER_NETWORK", :docker_worker_network) ||
        "bridge"

    if is_binary(network) and network != "" do
      args ++ ["--network", network]
    else
      args
    end
  end

  defp put_host_gateway_args(args, config) do
    docker = Map.get(config, "docker", %{})
    enabled = Map.get(docker, "add_host_gateway", Map.get(config, "add_host_gateway", true))

    if truthy?(enabled) do
      args ++ ["--add-host", "host.docker.internal:host-gateway"]
    else
      args
    end
  end

  defp put_gpu_args(args, config, opts) do
    allocation =
      Keyword.get(opts, :allocation) || Map.get(config, "__mirror_neuron_allocation", %{})

    devices = Map.get(allocation || %{}, "devices", [])
    docker = Map.get(config, "docker", %{})
    gpus = Map.get(docker, "gpus", Map.get(config, "gpus"))

    cond do
      is_binary(gpus) and gpus != "" ->
        args ++ ["--gpus", gpus]

      gpus in [true, "true", "1", "yes", "all"] ->
        args ++ ["--gpus", "all"]

      Enum.any?(devices, &gpu_device?/1) ->
        args ++ ["--gpus", "all"]

      true ->
        args
    end
  end

  defp put_shared_storage_mount(args, config) do
    env = config_env(config)

    case runtime_shared_storage_root(env) do
      nil ->
        args

      target_root ->
        source_root = host_shared_storage_root()
        File.mkdir_p(source_root)
        args ++ ["-v", "#{source_root}:#{target_root}:rw"]
    end
  end

  defp host_shared_storage_root do
    (MirrorNeuron.Config.optional_string("MN_HOST_SHARED_STORAGE_ROOT", :host_shared_storage_root) ||
       MirrorNeuron.Config.optional_string("MN_SHARED_STORAGE_ROOT", :shared_storage_root) ||
       SharedStorage.root())
    |> Path.expand()
  end

  defp runtime_shared_storage_root(env) do
    env
    |> Map.get("MN_JOB_SHARED_STORAGE_ROOT")
    |> case do
      value when is_binary(value) and value != "" ->
        value
        |> Path.dirname()
        |> Path.dirname()

      _ ->
        nil
    end
  end

  defp config_env(config) do
    case Map.get(config, "environment") do
      env when is_map(env) ->
        Enum.into(env, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)

      _ ->
        %{}
    end
  end

  defp put_allocation_volumes(args, config, opts) do
    allocation =
      Keyword.get(opts, :allocation) || Map.get(config, "__mirror_neuron_allocation", %{})

    allocation
    |> Map.get("volumes", [])
    |> Enum.reduce(args, fn volume, acc ->
      source = Map.get(volume, "source")
      target = Map.get(volume, "target")
      mode = Map.get(volume, "mode", "ro")

      if is_binary(source) and is_binary(target) do
        acc ++ ["-v", "#{source}:#{target}:#{mode}"]
      else
        acc
      end
    end)
  end

  defp gpu_device?(device) do
    kind = String.downcase(to_string(Map.get(device, "kind") || Map.get(device, :kind)))
    type = String.downcase(to_string(Map.get(device, "type") || Map.get(device, :type)))
    caps = Map.get(device, "capabilities") || Map.get(device, :capabilities) || []

    kind == "gpu" or String.contains?(type, "gpu") or "gpu" in Enum.map(caps, &to_string/1)
  end

  defp build_container_name(job_id, config) do
    prefix = Map.get(config, "docker_shared_container_prefix", "mn-docker-job")
    node_tag = Node.self() |> to_string() |> String.replace(~r/[^a-zA-Z0-9]/, "-")

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

  defp missing_container?(logs) when is_binary(logs),
    do: String.contains?(String.downcase(logs), "no such container")

  defp missing_container?(_logs), do: false

  defp docker_bin(config) do
    Map.get(config, "docker_bin") ||
      get_in(config, ["docker", "bin"]) ||
      MirrorNeuron.Config.optional_string("MN_DOCKER_BIN", :docker_bin) ||
      System.find_executable("docker") ||
      "docker"
  end

  defp prepared_sandbox(job_id, image, config) do
    case prepared_container_name(config) do
      name when is_binary(name) and name != "" ->
        {:ok,
         %{
           "container_name" => name,
           "image" => image,
           "workdir_root" => @container_root
         }}

      _ ->
        {:error,
         "docker_worker sandbox for job #{job_id} is not prepared; prepare DockerWorker resources with mn-python-sdk/API/CLI and provide docker_worker_container_name or MN_DOCKER_WORKER_CONTAINER_NAME"}
    end
  end

  defp prepared_container_name(config) do
    env = config_env(config)

    Map.get(config, "docker_worker_container_name") ||
      Map.get(config, "container_name") ||
      get_in(config, ["docker", "container_name"]) ||
      Map.get(env, "MN_DOCKER_WORKER_CONTAINER_NAME") ||
      System.get_env("MN_DOCKER_WORKER_CONTAINER_NAME")
  end

  defp native_sandbox_prep_enabled? do
    System.get_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false

  defp key(job_id), do: {:docker_worker, job_id}
  defp via(job_id), do: {:via, Registry, {@registry, key(job_id)}}
end
