defmodule MirrorNeuron.Runner.DockerWorker do
  @moduledoc false

  alias MirrorNeuron.Config
  alias MirrorNeuron.Message
  alias MirrorNeuron.Sandbox.DockerJobSandbox

  @default_container_workdir "/mn/job"
  @default_payloads_dir "/mn/payloads"

  def run(payload, config, opts \\ []) do
    runner_name = build_runner_name(config, opts)

    base_dir =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_docker_worker_#{runner_name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    message = build_message(payload, config, opts)

    try do
      with :ok <- reject_published_ports(config),
           :ok <- copy_uploads(base_dir, config, opts),
           :ok <- write_runtime_files(base_dir, message, opts),
           {:ok, image} <- resolve_image(config, base_dir),
           {:ok, output, exit_code, command_name} <-
             run_worker_command(image, base_dir, config, opts) do
        result =
          sanitize_result(%{
            "sandbox_name" => runner_name,
            "container_name" => command_name,
            "exit_code" => exit_code,
            "runner_exit_code" => exit_code,
            "stdout" => output,
            "stderr" => "",
            "logs" => String.trim(output),
            "raw_output" => output,
            "runner" => "docker_worker",
            "image" => image,
            "node_name" => to_string(Node.self())
          })

        if exit_code == 0, do: {:ok, result}, else: {:error, result}
      end
    after
      File.rm_rf(base_dir)
    end
  end

  defp resolve_image(config, base_dir) do
    image =
      Map.get(config, "image") ||
        Map.get(config, "docker_image") ||
        get_in(config, ["docker", "image"])

    build_source =
      Map.get(config, "docker_worker_image") ||
        Map.get(config, "build") ||
        get_in(config, ["docker", "build"])

    cond do
      is_binary(build_source) and String.trim(build_source) != "" ->
        build_worker_image(base_dir, build_source, image)

      is_binary(image) and image != "" ->
        {:ok, image}

      true ->
        {:error,
         "docker_worker requires config.image, config.docker.image, or config.docker_worker_image"}
    end
  end

  defp build_worker_image(base_dir, build_source, image) do
    with {:ok, source_path} <- resolve_build_source(base_dir, build_source),
         image_ref <- build_image_ref(source_path, image),
         {output, exit_code} <-
           System.cmd(docker_bin(), ["build", "-t", image_ref, source_path],
             stderr_to_stdout: true
           ) do
      if exit_code == 0 do
        {:ok, image_ref}
      else
        {:error,
         "failed to build docker_worker image from #{build_source}: #{String.trim(output)}"}
      end
    end
  rescue
    error ->
      {:error,
       "failed to build docker_worker image from #{build_source}: #{Exception.message(error)}"}
  end

  defp resolve_build_source(base_dir, build_source) do
    root = Path.expand(base_dir)

    candidate =
      if Path.type(build_source) == :absolute do
        Path.expand(build_source)
      else
        Path.expand(build_source, root)
      end

    cond do
      not inside_path?(candidate, root) ->
        {:error, "docker_worker build source must stay inside staged payloads: #{build_source}"}

      File.dir?(candidate) and File.regular?(Path.join(candidate, "Dockerfile")) ->
        {:ok, candidate}

      File.regular?(candidate) and Path.basename(candidate) == "Dockerfile" ->
        {:ok, Path.dirname(candidate)}

      true ->
        {:error, "docker_worker build source does not contain a Dockerfile: #{build_source}"}
    end
  end

  defp build_image_ref(_source_path, image) when is_binary(image) and image != "", do: image

  defp build_image_ref(source_path, _image) do
    digest =
      :crypto.hash(:sha256, source_path) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    "mirror-neuron/docker-worker:#{digest}"
  end

  defp reject_published_ports(config) do
    docker = Map.get(config, "docker", %{})

    cond do
      nonempty?(Map.get(config, "publish_ports")) ->
        {:error,
         "docker_worker does not publish host ports; use BEAM/core messaging or declared service ports"}

      nonempty?(Map.get(docker, "publish_ports")) ->
        {:error,
         "docker_worker does not publish host ports; use BEAM/core messaging or declared service ports"}

      nonempty?(Map.get(docker, "ports")) ->
        {:error,
         "docker_worker does not publish host ports; use BEAM/core messaging or declared service ports"}

      true ->
        :ok
    end
  end

  defp build_message(payload, config, opts) do
    case Keyword.get(opts, :message) do
      nil ->
        Message.new(
          Keyword.get(opts, :job_id),
          "runtime",
          Keyword.get(opts, :agent_id),
          Map.get(config, "output_message_type", "executor_input"),
          payload,
          content_type: Map.get(config, "content_type", "application/json"),
          content_encoding: Map.get(config, "content_encoding", "identity")
        )

      message ->
        Message.normalize!(
          message,
          job_id: Keyword.get(opts, :job_id),
          to: Keyword.get(opts, :agent_id),
          content_type: Map.get(config, "content_type", "application/json"),
          content_encoding: Map.get(config, "content_encoding", "identity")
        )
    end
  end

  defp write_runtime_files(base_dir, message, opts) do
    with :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_input.json"),
             Jason.encode!(Message.body(message), pretty: true)
           ),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_message.json"),
             Jason.encode!(message, pretty: true)
           ),
         {:ok, body_binary} <- Message.body_binary(message),
         :ok <- File.write(Path.join(base_dir, "mirror_neuron_body.bin"), body_binary),
         :ok <-
           File.write(
             Path.join(base_dir, "mirror_neuron_context.json"),
             Jason.encode!(
               %{
                 job_id: Keyword.get(opts, :job_id),
                 agent_id: Keyword.get(opts, :agent_id),
                 agent_type: Keyword.get(opts, :agent_type),
                 template_type: Keyword.get(opts, :template_type, "generic"),
                 agent_state: Keyword.get(opts, :agent_state, %{}),
                 timestamp: MirrorNeuron.Runtime.timestamp()
               },
               pretty: true
             )
           ) do
      :ok
    end
  end

  defp build_docker_args(image, base_dir, config, opts) do
    container_name = docker_name(config, opts)
    container_workdir = container_workdir(config)
    payloads_dir = @default_payloads_dir
    command = normalize_command(Map.get(config, "command"))
    env = runtime_env(container_workdir, payloads_dir, config, opts)

    args =
      ["run", "--rm", "--name", container_name]
      |> put_network_args(config)
      |> put_host_gateway_args(config)
      |> put_gpu_args(config, opts)
      |> Kernel.++(["-v", "#{Path.expand(base_dir)}:#{@default_container_workdir}:rw"])
      |> put_payload_mount(opts)
      |> put_allocation_volumes(config, opts)
      |> Kernel.++(["-w", container_workdir])
      |> put_env_args(env)
      |> Kernel.++([image])
      |> Kernel.++(command)

    {:ok, args, container_name}
  end

  defp run_worker_command(image, base_dir, config, opts) do
    if shared_container?(config, opts) do
      run_shared_docker(image, base_dir, config, opts)
    else
      with {:ok, docker_args, command_name} <- build_docker_args(image, base_dir, config, opts),
           {:ok, output, exit_code} <- run_docker(docker_args, command_name, config) do
        {:ok, output, exit_code, command_name}
      end
    end
  end

  defp run_shared_docker(image, base_dir, config, opts) do
    job_id = Keyword.fetch!(opts, :job_id)

    with {:ok, sandbox} <- DockerJobSandbox.ensure(job_id, image, config, opts) do
      container_name = sandbox["container_name"]
      remote_dir = build_shared_remote_dir(config, opts)

      try do
        with :ok <- prepare_shared_remote_dir(container_name, remote_dir, config),
             :ok <- copy_to_shared_container(container_name, base_dir, remote_dir, config),
             {:ok, docker_args} <-
               build_docker_exec_args(container_name, remote_dir, config, opts),
             {:ok, output, exit_code} <- run_docker(docker_args, container_name, config) do
          {:ok, output, exit_code, container_name}
        end
      after
        cleanup_shared_remote_dir(container_name, remote_dir, config)
      end
    end
  end

  defp build_docker_exec_args(container_name, remote_dir, config, opts) do
    workdir = resolve_shared_workdir(config, remote_dir)
    command = normalize_command(Map.get(config, "command"))
    env = runtime_env(workdir, remote_dir, config, opts, remote_dir)

    args =
      ["exec", "-w", workdir]
      |> put_env_args(env)
      |> Kernel.++([container_name])
      |> Kernel.++(command)

    {:ok, args}
  end

  defp prepare_shared_remote_dir(container_name, remote_dir, config) do
    case System.cmd(docker_bin(config), ["exec", container_name, "mkdir", "-p", remote_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError ->
      {:error, "failed to prepare shared DockerWorker workspace: #{Exception.message(error)}"}
  end

  defp copy_to_shared_container(container_name, base_dir, remote_dir, config) do
    source = Path.join(Path.expand(base_dir), ".")

    case System.cmd(docker_bin(config), ["cp", source, "#{container_name}:#{remote_dir}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, %{"exit_code" => exit_code, "logs" => output}}
    end
  rescue
    error in ErlangError ->
      {:error,
       "failed to copy DockerWorker workspace into shared container: #{Exception.message(error)}"}
  end

  defp cleanup_shared_remote_dir(container_name, remote_dir, config) do
    if cleanup_remote_dir?(config) do
      _ =
        System.cmd(docker_bin(config), ["exec", container_name, "rm", "-rf", remote_dir],
          stderr_to_stdout: true
        )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp resolve_shared_workdir(config, remote_dir) do
    configured = container_workdir(config)

    cond do
      configured == @default_container_workdir ->
        remote_dir

      String.starts_with?(configured, @default_container_workdir <> "/") ->
        suffix = String.replace_prefix(configured, @default_container_workdir, "")
        remote_dir <> suffix

      true ->
        configured
    end
  end

  defp build_shared_remote_dir(_config, opts) do
    agent = safe_name(Keyword.get(opts, :agent_id, "agent"))
    attempt = Keyword.get(opts, :attempt, 1)
    invocation = Keyword.get(opts, :invocation, 1)
    unique = Integer.to_string(System.unique_integer([:positive]))

    Path.join([
      @default_container_workdir,
      "runs",
      agent,
      "i#{invocation}-a#{attempt}-#{unique}"
    ])
  end

  defp container_workdir(config) do
    case Map.get(config, "workdir") || get_in(config, ["docker", "workdir"]) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_container_workdir
    end
  end

  defp normalize_command(nil), do: ["sh", "-lc", "echo 'No command configured for docker worker'"]
  defp normalize_command(command) when is_binary(command), do: ["sh", "-lc", command]
  defp normalize_command(command) when is_list(command), do: Enum.map(command, &to_string/1)
  defp normalize_command(command), do: ["sh", "-lc", to_string(command)]

  defp runtime_env(
         container_workdir,
         payloads_dir,
         config,
         opts,
         bundle_root \\ @default_container_workdir
       ) do
    allocation =
      Keyword.get(opts, :allocation) || Map.get(config, "__mirror_neuron_allocation", %{})

    base = %{
      "MN_INPUT_FILE" => "#{bundle_root}/mirror_neuron_input.json",
      "MN_CONTEXT_FILE" => "#{bundle_root}/mirror_neuron_context.json",
      "MN_MESSAGE_FILE" => "#{bundle_root}/mirror_neuron_message.json",
      "MN_BODY_FILE" => "#{bundle_root}/mirror_neuron_body.bin",
      "MN_WORKDIR" => container_workdir,
      "MN_BUNDLE_ROOT" => bundle_root,
      "MN_PAYLOADS_DIR" => payloads_dir,
      "MN_JOB_ID" => to_string(Keyword.get(opts, :job_id, "")),
      "MN_AGENT_ID" => to_string(Keyword.get(opts, :agent_id, "")),
      "MN_AGENT_TYPE" => to_string(Keyword.get(opts, :agent_type, "")),
      "MN_RUNTIME_DRIVER" => "docker_worker"
    }

    base
    |> Map.merge(MirrorNeuron.ResourceSpec.allocation_env(allocation))
    |> Map.merge(extra_env(config))
  end

  defp shared_container?(config, opts) do
    shared? =
      Map.get(config, "reuse_shared_container", Map.get(config, "shared_container", true))

    Keyword.get(opts, :job_id) not in [nil, ""] and truthy?(shared?)
  end

  defp cleanup_remote_dir?(config) do
    Map.get(config, "cleanup_remote_dir", true) |> truthy?()
  end

  defp put_network_args(args, config) do
    docker = Map.get(config, "docker", %{})

    network =
      Map.get(docker, "network") ||
        Map.get(config, "network") ||
        System.get_env("MN_DOCKER_WORKER_NETWORK") ||
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

  defp put_payload_mount(args, opts) do
    case Keyword.get(opts, :payloads_path) do
      path when is_binary(path) ->
        expanded = Path.expand(path)

        if File.dir?(expanded) do
          args ++ ["-v", "#{expanded}:#{@default_payloads_dir}:ro"]
        else
          args
        end

      _ ->
        args
    end
  end

  defp put_allocation_volumes(args, config, opts) do
    allocation =
      Keyword.get(opts, :allocation) ||
        Map.get(config, "__mirror_neuron_allocation", %{})

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

  defp put_env_args(args, env) do
    env
    |> Enum.reduce(args, fn {key, value}, acc -> acc ++ ["-e", "#{key}=#{value}"] end)
  end

  defp run_docker(args, container_name, config) do
    docker_bin = docker_bin(config)
    executable = System.find_executable(docker_bin) || docker_bin
    timeout_ms = timeout_ms(config)
    deadline = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map(args, &String.to_charlist/1)}
        ]
      )

    collect_docker_output(port, container_name, config, [], 0, max_output_bytes(config), deadline)
  rescue
    error in ErlangError ->
      {:error, "failed to invoke docker worker: #{Exception.message(error)}"}
  end

  defp collect_docker_output(
         port,
         container_name,
         config,
         chunks,
         bytes,
         max_output_bytes,
         deadline
       ) do
    receive do
      {^port, {:data, data}} ->
        {next_chunks, next_bytes} = append_output(chunks, bytes, data, max_output_bytes)

        collect_docker_output(
          port,
          container_name,
          config,
          next_chunks,
          next_bytes,
          max_output_bytes,
          deadline
        )

      {^port, {:exit_status, exit_code}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_code}
    after
      receive_timeout(deadline) ->
        Port.close(port)
        cleanup_container(container_name, config)

        {:error,
         %{
           "error" => "docker worker command timed out",
           "timeout_ms" => timeout_ms_from_deadline(deadline),
           "stdout" => chunks |> Enum.reverse() |> IO.iodata_to_binary()
         }}
    end
  end

  defp append_output(chunks, bytes, data, max_output_bytes) do
    cond do
      bytes >= max_output_bytes ->
        {chunks, bytes + byte_size(data)}

      bytes + byte_size(data) <= max_output_bytes ->
        {[data | chunks], bytes + byte_size(data)}

      true ->
        remaining = max(max_output_bytes - bytes, 0)
        truncated = binary_part(data, 0, remaining) <> "\n[truncated by docker worker output cap]"
        {[truncated | chunks], bytes + byte_size(data)}
    end
  end

  defp receive_timeout(nil), do: :infinity

  defp receive_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp timeout_ms_from_deadline(nil), do: nil

  defp timeout_ms_from_deadline(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp cleanup_container(container_name, config) do
    _ = System.cmd(docker_bin(config), ["rm", "-f", container_name], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp copy_uploads(base_dir, config, opts) do
    payloads_path = Keyword.get(opts, :payloads_path)
    coordinator_node = Keyword.get(opts, :coordinator_node, Node.self())

    entries =
      case Map.get(config, "upload_paths") do
        paths when is_list(paths) and paths != [] ->
          Enum.map(paths, fn entry ->
            %{
              "source" => Map.fetch!(entry, "source"),
              "target" => Map.get(entry, "target", Path.basename(Map.fetch!(entry, "source")))
            }
          end)

        _ ->
          case Map.get(config, "upload_path") do
            nil ->
              []

            source ->
              [
                %{
                  "source" => source,
                  "target" => Map.get(config, "upload_as", Path.basename(source))
                }
              ]
          end
      end

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with {:ok, source} <- resolve_upload_source(entry["source"], payloads_path),
           {:ok, target} <- resolve_upload_target(base_dir, entry["target"]) do
        copy_upload_entry(source, target, coordinator_node)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_upload_entry(source, target, coordinator_node) do
    is_local = coordinator_node == Node.self()

    cond do
      is_local and File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))

        case File.cp_r(source, target) do
          {:ok, _files} -> {:cont, :ok}
          {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
        end

      is_local and File.exists?(source) ->
        File.mkdir_p!(Path.dirname(target))

        case File.cp(source, target) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end

      not is_local ->
        copy_remote_upload(source, target, coordinator_node)

      true ->
        {:halt, {:error, "upload source does not exist locally: #{source}"}}
    end
  end

  defp copy_remote_upload(source, target, coordinator_node) do
    is_dir = :rpc.call(coordinator_node, File, :dir?, [source], 30_000)

    if is_dir == true do
      files =
        :rpc.call(
          coordinator_node,
          MirrorNeuron.Runner.HostLocal,
          :list_all_files,
          [source],
          30_000
        )

      Enum.each(files, fn rel_path ->
        content = :rpc.call(coordinator_node, File, :read!, [Path.join(source, rel_path)], 30_000)
        file_target = Path.join(target, rel_path)
        File.mkdir_p!(Path.dirname(file_target))
        File.write!(file_target, content)
      end)

      {:cont, :ok}
    else
      is_file = :rpc.call(coordinator_node, File, :exists?, [source], 30_000)

      if is_file == true do
        content = :rpc.call(coordinator_node, File, :read!, [source], 30_000)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, content)
        {:cont, :ok}
      else
        {:halt,
         {:error, "upload source does not exist remotely on #{coordinator_node}: #{source}"}}
      end
    end
  end

  defp resolve_upload_source(source, nil), do: {:ok, Path.expand(source)}

  defp resolve_upload_source(source, payloads_path) do
    payloads_root = Path.expand(payloads_path)

    resolved =
      if Path.type(source) == :absolute do
        Path.expand(source)
      else
        Path.expand(source, payloads_root)
      end

    if inside_path?(resolved, payloads_root) do
      {:ok, resolved}
    else
      {:error, "upload source must stay inside blueprint payloads: #{source}"}
    end
  end

  defp resolve_upload_target(base_dir, target) do
    resolved = Path.expand(target, base_dir)

    if inside_path?(resolved, Path.expand(base_dir)) do
      {:ok, resolved}
    else
      {:error, "upload target must stay inside docker worker workspace: #{target}"}
    end
  end

  defp inside_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp build_runner_name(config, opts) do
    [
      Map.get(config, "name"),
      Keyword.get(opts, :job_id),
      Keyword.get(opts, :agent_id),
      Keyword.get(opts, :attempt, 1),
      Keyword.get(opts, :invocation, 1)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&safe_name/1)
    |> Enum.join("-")
    |> case do
      "" -> "worker"
      value -> String.slice(value, 0, 96)
    end
  end

  defp docker_name(config, opts), do: "mn-#{build_runner_name(config, opts)}"

  defp safe_name(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim("-")
  end

  defp docker_bin(config \\ %{}) do
    Map.get(config, "docker_bin") ||
      get_in(config, ["docker", "bin"]) ||
      System.get_env("MN_DOCKER_BIN") ||
      System.find_executable("docker") ||
      "docker"
  end

  defp timeout_ms(config) do
    case Map.get(config, "timeout_seconds") do
      value when is_integer(value) and value > 0 -> value * 1000
      value when is_float(value) and value > 0 -> trunc(value * 1000)
      _ -> nil
    end
  end

  defp max_output_bytes(config) do
    case Map.get(config, "max_output_bytes") do
      value when is_integer(value) and value > 0 -> value
      _ -> System.get_env("MN_MAX_ARTIFACT_BYTES", "1048576") |> String.to_integer()
    end
  end

  defp extra_env(config) do
    case Map.get(config, "environment") do
      env when is_map(env) ->
        Enum.into(env, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)

      _ ->
        %{}
    end
  end

  defp gpu_device?(device) do
    kind = String.downcase(to_string(Map.get(device, "kind") || Map.get(device, :kind)))
    type = String.downcase(to_string(Map.get(device, "type") || Map.get(device, :type)))
    caps = Map.get(device, "capabilities") || Map.get(device, :capabilities) || []

    kind == "gpu" or String.contains?(type, "gpu") or "gpu" in Enum.map(caps, &to_string/1)
  end

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false

  defp nonempty?(value) when is_list(value), do: value != []
  defp nonempty?(value) when is_map(value), do: map_size(value) > 0
  defp nonempty?(_value), do: false

  defp sanitize_result(result) do
    Enum.into(result, %{}, fn
      {key, value} when is_binary(value) ->
        {key, value |> redact_secrets() |> truncate_artifact()}

      entry ->
        entry
    end)
  end

  defp redact_secrets(text) do
    System.get_env()
    |> Enum.filter(fn {key, value} ->
      value != "" and String.match?(key, ~r/(TOKEN|SECRET|KEY|COOKIE|PASSWORD)/i)
    end)
    |> Enum.reduce(text, fn {_key, value}, acc -> String.replace(acc, value, "[REDACTED]") end)
  end

  defp truncate_artifact(text) do
    max_bytes =
      System.get_env("MN_MAX_ARTIFACT_BYTES", "1048576")
      |> String.to_integer()

    if byte_size(text) > max_bytes do
      binary_part(text, 0, max_bytes) <> "\n[truncated by MN_MAX_ARTIFACT_BYTES]"
    else
      text
    end
  end
end
