defmodule MirrorNeuron.Runner.DockerWorker do
  @moduledoc false

  alias MirrorNeuron.Config
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Message
  alias MirrorNeuron.Sandbox.DockerJobSandbox

  @default_container_workdir "/mn/job"
  @default_payloads_dir "/mn/payloads"
  @default_agent_event_prefix "__MN_EVENT__"
  @prepared_model_env_vars [
    "MN_NODE_RUNTIME_MODELS",
    "MN_NODE_MODELS",
    "MN_DOCKER_MODEL_RUNNER_MODEL",
    "MN_LLM_MODEL_RUNNER_MODEL"
  ]

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
           :ok <- copy_build_context_uploads(base_dir, config, opts),
           :ok <- write_runtime_files(base_dir, message, opts),
           {:ok, image} <- resolve_image(config, base_dir, opts),
           :ok <- ensure_docker_model_runner_model(config, opts),
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

  defp resolve_image(config, base_dir, opts) do
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
        build_worker_image(base_dir, build_source, image, config, opts)

      is_binary(image) and image != "" ->
        {:ok, image}

      true ->
        {:error,
         "docker_worker requires config.image, config.docker.image, or config.docker_worker_image"}
    end
  end

  defp build_worker_image(base_dir, build_source, image, config, opts) do
    if not native_prep_enabled?() do
      {:error,
       "docker_worker image build is owned by mn-python-sdk/API/CLI; submit a prepared image via config.image or config.docker.image instead of docker_worker_image/build"}
    else
      legacy_build_worker_image(base_dir, build_source, image, config, opts)
    end
  end

  defp legacy_build_worker_image(base_dir, build_source, image, config, opts) do
    with {:ok, source_path} <- resolve_build_source(base_dir, build_source),
         image_ref <- build_image_ref(source_path, image),
         :ok <-
           emit_runner_event(opts, "docker_worker_build_started", %{
             "category" => "system",
             "message" => "DockerWorker image build started",
             "status" => "started",
             "runner" => "docker_worker",
             "target" => build_source,
             "image" => image_ref
           }),
         {output, exit_code} <-
           System.cmd(docker_bin(config), ["build", "-t", image_ref, source_path],
             stderr_to_stdout: true,
             env: docker_build_env(config)
           ) do
      if exit_code == 0 do
        emit_runner_event(opts, "docker_worker_build_completed", %{
          "category" => "system",
          "message" => "DockerWorker image build completed",
          "status" => "completed",
          "runner" => "docker_worker",
          "target" => build_source,
          "image" => image_ref,
          "result_summary" => compact_output_tail(output)
        })

        {:ok, image_ref}
      else
        emit_runner_event(opts, "docker_worker_build_failed", %{
          "category" => "error",
          "message" => "DockerWorker image build failed",
          "status" => "failed",
          "runner" => "docker_worker",
          "target" => build_source,
          "image" => image_ref,
          "result_summary" => compact_output_tail(output),
          "details" => %{"exit_code" => exit_code}
        })

        {:error,
         "failed to build docker_worker image from #{build_source}: #{String.trim(output)}"}
      end
    end
  rescue
    error ->
      emit_runner_event(opts, "docker_worker_build_failed", %{
        "category" => "error",
        "message" => "DockerWorker image build failed",
        "status" => "failed",
        "runner" => "docker_worker",
        "target" => build_source,
        "result_summary" => Exception.message(error)
      })

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

  defp docker_build_env(config) do
    buildkit =
      Map.get(config, "docker_buildkit") ||
        get_in(config, ["docker", "buildkit"]) ||
        Config.optional_string("MN_DOCKER_WORKER_BUILDKIT", :docker_worker_buildkit) ||
        "0"

    [{"DOCKER_BUILDKIT", docker_buildkit_value(buildkit)}]
  end

  defp docker_buildkit_value(value) when value in [true, 1, "1"], do: "1"

  defp docker_buildkit_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> "1"
      "yes" -> "1"
      "on" -> "1"
      _ -> "0"
    end
  end

  defp docker_buildkit_value(_value), do: "0"

  defp ensure_docker_model_runner_model(config, opts) do
    env = extra_env(config)
    provider = env |> Map.get("MN_LLM_PROVIDER", "") |> to_string() |> String.trim()

    if provider in ["docker_model_runner", "docker-model-runner", "dmr"] do
      model =
        env
        |> Map.get("MN_LLM_RUNTIME_MODEL", Map.get(env, "MN_LLM_MODEL", ""))
        |> to_string()
        |> String.trim()

      if model == "" do
        :ok
      else
        do_ensure_docker_model_runner_model(model, env, config, opts)
      end
    else
      :ok
    end
  end

  defp do_ensure_docker_model_runner_model(model, env, _config, opts) do
    runtime_env = Map.merge(System.get_env(), env)

    cond do
      managed_runtime_model?(runtime_env) ->
        emit_runner_event(opts, "docker_worker_model_prepare_deferred", %{
          "category" => "system",
          "message" =>
            "Runtime model #{model} will be selected and prepared on first LLM call from worker on #{Node.self()}",
          "status" => "deferred",
          "runner" => "docker_worker",
          "model" => model,
          "logical_model" => model,
          "execution_node" => to_string(Node.self()),
          "preparation" => "lazy_first_use"
        })

        :ok

      model_endpoint_prepared?(model, runtime_env) ->
        :ok

      node_runtime_model_prepared?(model, runtime_env) ->
        :ok

      true ->
        emit_runner_event(opts, "docker_worker_model_not_prepared", %{
          "category" => "error",
          "message" => "DockerWorker runtime model was not prepared",
          "status" => "failed",
          "runner" => "docker_worker",
          "model" => model,
          "node_name" => to_string(Node.self())
        })

        {:error,
         "Docker Model Runner model #{model} is not prepared on #{Node.self()}; prepare it with mn-python-sdk/API/CLI before submitting the job or provide MN_MODEL_ENDPOINTS_JSON"}
    end
  rescue
    error ->
      {:error, "failed to check Docker Model Runner model #{model}: #{Exception.message(error)}"}
  end

  defp managed_runtime_model?(env),
    do: env |> Map.get("MN_RUNTIME_MODEL_MANAGED") |> truthy?()

  defp model_endpoint_prepared?(model, env) do
    endpoints = Map.get(env, "MN_MODEL_ENDPOINTS_JSON", "")

    with true <- is_binary(endpoints) and String.trim(endpoints) != "",
         {:ok, decoded} <- Jason.decode(endpoints),
         true <- is_map(decoded) do
      model_keys = model_match_keys(model)

      Enum.any?(decoded, fn {key, value} ->
        endpoint_keys =
          [key]
          |> Kernel.++(if(is_map(value), do: [value["model"], value["runtime_model"]], else: []))
          |> Enum.flat_map(&model_match_keys/1)
          |> MapSet.new()

        not MapSet.disjoint?(model_keys, endpoint_keys)
      end)
    else
      _ -> false
    end
  end

  defp node_runtime_model_prepared?(model, env) do
    requested_keys = model_match_keys(model)

    env
    |> prepared_model_refs()
    |> Enum.any?(fn ref ->
      not MapSet.disjoint?(requested_keys, model_match_keys(ref))
    end)
  end

  defp prepared_model_refs(env) do
    env_refs =
      @prepared_model_env_vars
      |> Enum.flat_map(fn name ->
        env
        |> Map.get(name)
        |> split_env_list()
      end)

    (env_refs ++ prepared_runtime_model_refs(env))
    |> Enum.uniq_by(&(to_string(&1) |> String.downcase()))
  end

  defp prepared_runtime_model_refs(env) do
    raw = Map.get(env, "MN_PREPARED_RUNTIME_MODELS_JSON", "")

    with true <- is_binary(raw) and String.trim(raw) != "",
         {:ok, values} when is_list(values) <- Jason.decode(raw) do
      values
      |> Enum.map(&(to_string(&1) |> String.trim()))
      |> Enum.reject(&(&1 == ""))
    else
      _ -> []
    end
  end

  defp split_env_list(nil), do: []

  defp split_env_list(value) do
    value
    |> to_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp model_match_keys(value) do
    text =
      value
      |> to_string()
      |> String.trim()

    if text == "" do
      MapSet.new()
    else
      lower = String.downcase(text)

      lower
      |> model_match_key_variants()
      |> MapSet.new()
    end
  end

  defp model_match_key_variants(value) do
    no_ai = String.replace_prefix(value, "ai/", "")
    no_latest = String.replace_suffix(value, ":latest", "")
    no_ai_latest = no_ai |> String.replace_suffix(":latest", "")

    [value, no_ai, no_latest, no_ai_latest]
    |> Enum.flat_map(fn key ->
      if String.contains?(key, "/") do
        [key]
      else
        [key, "ai/#{key}"]
      end
    end)
    |> Enum.reject(&(&1 == "" or &1 == "ai/"))
    |> Enum.uniq()
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
    command = normalize_command(Map.get(config, "command")) |> wrap_runtime_bootstrap_command()
    env = runtime_env(container_workdir, payloads_dir, config, opts)

    args =
      ["run", "--rm", "--name", container_name]
      |> put_network_args(config)
      |> put_host_gateway_args(config)
      |> put_gpu_args(config, opts)
      |> Kernel.++(["-v", "#{Path.expand(base_dir)}:#{@default_container_workdir}:rw"])
      |> put_shared_storage_mount(config)
      |> put_payload_mount(opts)
      |> put_allocation_volumes(config, opts)
      |> Kernel.++(["-w", container_workdir])
      |> put_env_args(env)
      |> Kernel.++([image])
      |> Kernel.++(command)

    {:ok, args, container_name}
  end

  defp run_worker_command(image, base_dir, config, opts) do
    if DockerJobSandbox.prepared_container?(config) or shared_container?(config, opts) or
         not native_sandbox_prep_enabled?() do
      run_shared_docker(image, base_dir, config, opts)
    else
      with {:ok, docker_args, command_name} <- build_docker_args(image, base_dir, config, opts),
           {:ok, output, exit_code} <- run_docker(docker_args, command_name, config, opts) do
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
             {:ok, output, exit_code} <- run_docker(docker_args, container_name, config, opts) do
          {:ok, output, exit_code, container_name}
        end
      after
        cleanup_shared_remote_dir(container_name, remote_dir, config)
      end
    end
  end

  defp build_docker_exec_args(container_name, remote_dir, config, opts) do
    workdir = resolve_shared_workdir(config, remote_dir)
    command = normalize_command(Map.get(config, "command")) |> wrap_runtime_bootstrap_command()
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
    |> Map.put("MN_EXECUTION_NODE", to_string(Node.self()))
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
    environment = extra_env(config)
    configured_network = Map.get(docker, "network") || Map.get(config, "network")

    network =
      if is_binary(configured_network) do
        configured_network
      else
        nonempty_string(Map.get(environment, "MN_DOCKER_WORKER_NETWORK")) ||
          Config.optional_string("MN_DOCKER_WORKER_NETWORK", :docker_worker_network) ||
          "bridge"
      end

    if is_binary(network) and network != "" do
      args ++ ["--network", network]
    else
      args
    end
  end

  defp nonempty_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp nonempty_string(_value), do: nil

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

  defp put_shared_storage_mount(args, config) do
    env = extra_env(config)

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
    (Config.optional_string("MN_HOST_SHARED_STORAGE_ROOT", :host_shared_storage_root) ||
       Config.optional_string("MN_SHARED_STORAGE_ROOT", :shared_storage_root) ||
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

  defp wrap_runtime_bootstrap_command(command) do
    [
      "sh",
      "-lc",
      """
      for root in "$MN_WORKDIR/.mn-local-skills" "$MN_BUNDLE_ROOT/.mn-local-skills" "/mn/job/.mn-local-skills"; do
        if [ -d "$root" ]; then
          for src in "$root"/*/src; do
            if [ -d "$src" ]; then
              PYTHONPATH="$src${PYTHONPATH:+:$PYTHONPATH}"
            fi
          done
        fi
      done
      export PYTHONPATH
      exec "$@"
      """,
      "mn-docker-worker-runtime"
    ] ++ command
  end

  defp run_docker(args, container_name, config, opts) do
    docker_bin = docker_bin(config)
    executable = System.find_executable(docker_bin) || docker_bin
    timeout_ms = timeout_ms(config)
    deadline = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms
    event_state = agent_event_state(config, opts)

    emit_runner_event(opts, "docker_worker_command_started", %{
      "category" => "system",
      "message" => "DockerWorker command started",
      "status" => "started",
      "runner" => "docker_worker",
      "target" => container_name
    })

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

    collect_docker_output(
      port,
      container_name,
      config,
      opts,
      [],
      0,
      max_output_bytes(config),
      deadline,
      event_state
    )
  rescue
    error in ErlangError ->
      {:error, "failed to invoke docker worker: #{Exception.message(error)}"}
  end

  defp collect_docker_output(
         port,
         container_name,
         config,
         opts,
         chunks,
         bytes,
         max_output_bytes,
         deadline,
         event_state
       ) do
    receive do
      {^port, {:data, data}} ->
        {clean_data, next_event_state} = filter_agent_event_output(data, event_state)
        {next_chunks, next_bytes} = append_output(chunks, bytes, clean_data, max_output_bytes)

        collect_docker_output(
          port,
          container_name,
          config,
          opts,
          next_chunks,
          next_bytes,
          max_output_bytes,
          deadline,
          next_event_state
        )

      {^port, {:exit_status, exit_code}} ->
        {tail, next_event_state} = flush_agent_event_buffer(event_state)
        {next_chunks, _next_bytes} = append_output(chunks, bytes, tail, max_output_bytes)
        output = next_chunks |> Enum.reverse() |> IO.iodata_to_binary()

        emit_runner_event(opts, "docker_worker_command_completed", %{
          "category" => if(exit_code == 0, do: "system", else: "error"),
          "message" =>
            if(exit_code == 0,
              do: "DockerWorker command completed",
              else: "DockerWorker command failed"
            ),
          "status" => if(exit_code == 0, do: "completed", else: "failed"),
          "runner" => "docker_worker",
          "target" => container_name,
          "result_summary" => compact_output_tail(output),
          "details" => %{
            "exit_code" => exit_code,
            "agent_event_prefix" => next_event_state.prefix
          }
        })

        {:ok, output, exit_code}
    after
      receive_timeout(deadline) ->
        Port.close(port)
        cleanup_container(container_name, config)
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

        emit_runner_event(opts, "docker_worker_command_timed_out", %{
          "category" => "error",
          "message" => "DockerWorker command timed out",
          "status" => "failed",
          "runner" => "docker_worker",
          "target" => container_name,
          "duration_ms" => timeout_ms_from_deadline(deadline),
          "result_summary" => compact_output_tail(output)
        })

        {:error,
         %{
           "error" => "docker worker command timed out",
           "timeout_ms" => timeout_ms_from_deadline(deadline),
           "stdout" => output
         }}
    end
  end

  defp agent_event_state(config, opts) do
    environment = Map.get(config, "environment", %{})

    %{
      prefix: agent_event_prefix(config),
      line_buffer: "",
      event_callback: Keyword.get(opts, :event_callback),
      job_id: to_string(Keyword.get(opts, :job_id, "")),
      agent_id: to_string(Keyword.get(opts, :agent_id, "")),
      step:
        to_string(
          Map.get(environment, "MN_WORKFLOW_STEP_ID") ||
            Keyword.get(opts, :agent_id, "")
        ),
      attempt: Keyword.get(opts, :attempt, 1)
    }
  end

  defp agent_event_prefix(config) do
    case Map.get(config, "agent_event_stdout_prefix") do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> @default_agent_event_prefix
    end
  end

  defp filter_agent_event_output(data, state) do
    combined = state.line_buffer <> data
    parts = :binary.split(combined, "\n", [:global])
    complete_count = length(parts) - 1
    complete_lines = Enum.take(parts, complete_count)
    trailing = List.last(parts) || ""

    {clean_lines, next_state} =
      Enum.reduce(complete_lines, {[], %{state | line_buffer: trailing}}, fn line,
                                                                             {acc, current_state} ->
        line = String.trim_trailing(line, "\r")

        if String.starts_with?(line, current_state.prefix) do
          emit_agent_event_line(line, current_state)
          {acc, current_state}
        else
          {[line | acc], current_state}
        end
      end)

    clean_output =
      clean_lines
      |> Enum.reverse()
      |> Enum.map(&(&1 <> "\n"))
      |> IO.iodata_to_binary()

    {clean_output, next_state}
  end

  defp flush_agent_event_buffer(%{line_buffer: ""} = state), do: {"", state}

  defp flush_agent_event_buffer(state) do
    line = String.trim_trailing(state.line_buffer, "\r")

    if String.starts_with?(line, state.prefix) do
      emit_agent_event_line(line, state)
      {"", %{state | line_buffer: ""}}
    else
      {state.line_buffer, %{state | line_buffer: ""}}
    end
  end

  defp emit_agent_event_line(line, state) do
    raw_payload =
      line
      |> String.replace_prefix(state.prefix, "")
      |> String.trim()

    case Jason.decode(raw_payload) do
      {:ok, %{"type" => event_type, "payload" => payload}}
      when is_binary(event_type) and is_map(payload) ->
        emit_event(state, event_type, agent_event_payload(state, payload))

      {:ok, payload} when is_map(payload) ->
        event_type = Map.get(payload, "type", "agent_activity")

        emit_event(
          state,
          to_string(event_type),
          agent_event_payload(state, Map.drop(payload, ["type"]))
        )

      _ ->
        emit_event(
          state,
          "agent_activity",
          agent_event_payload(state, %{"message" => raw_payload, "category" => "agent"})
        )
    end
  end

  defp agent_event_payload(state, payload) do
    Map.merge(
      %{
        "schema" => "mn.agent.activity.v1",
        "job_id" => state.job_id,
        "agent_id" => state.agent_id,
        "step" => state.step,
        "step_id" => state.step,
        "attempt" => state.attempt,
        "source" => "agent",
        "category" => Map.get(payload, "category", "agent"),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      Map.drop(payload, [
        "schema",
        "job_id",
        "agent_id",
        "step",
        "step_id",
        "attempt",
        "source",
        "emitted_at"
      ])
    )
  end

  defp emit_runner_event(opts, event_type, payload) do
    case Keyword.get(opts, :event_callback) do
      callback when is_function(callback, 2) ->
        callback.(event_type, runner_event_payload(opts, payload))

      _ ->
        :ok
    end

    :ok
  end

  defp runner_event_payload(opts, payload) do
    agent_id = to_string(Keyword.get(opts, :agent_id, ""))

    Map.merge(
      %{
        "schema" => "mn.agent.activity.v1",
        "agent_id" => agent_id,
        "step" => agent_id,
        "step_id" => agent_id,
        "source" => "runtime",
        "category" => Map.get(payload, "category", "system"),
        "emitted_at" => MirrorNeuron.Runtime.timestamp()
      },
      payload
    )
  end

  defp emit_event(%{event_callback: callback}, event_type, payload)
       when is_function(callback, 2) do
    callback.(event_type, payload)
  end

  defp emit_event(_state, _event_type, _payload), do: :ok

  defp compact_output_tail(output, limit \\ 1200) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.take(-20)
    |> Enum.join("\n")
    |> String.trim()
    |> truncate_tail(limit)
  end

  defp truncate_tail(text, limit) when byte_size(text) <= limit, do: text

  defp truncate_tail(text, limit) do
    marker = "[truncated]\n"
    keep = max(limit - byte_size(marker), 0)
    start = max(byte_size(text) - keep, 0)
    marker <> binary_part(text, start, min(keep, byte_size(text) - start))
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
        copy_upload_entry(source, target, coordinator_node, config, opts)
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_build_context_uploads(base_dir, config, opts) do
    entries =
      case Map.get(config, "build_context_upload_paths") do
        paths when is_list(paths) -> paths
        _ -> []
      end

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with {:ok, source} <- resolve_build_context_source(entry, config, opts),
           {:ok, target_name} <- resolve_build_context_target(entry),
           {:ok, target} <- resolve_upload_target(base_dir, target_name) do
        copy_upload_entry(
          source,
          target,
          Keyword.get(opts, :coordinator_node, Node.self()),
          config,
          opts
        )
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_build_context_target(%{"target" => target})
       when is_binary(target) and target != "",
       do: {:ok, target}

  defp resolve_build_context_target(_entry),
    do: {:error, "build_context_upload_paths entry requires target"}

  defp resolve_build_context_source(entry, config, opts) when is_map(entry) do
    source = Map.get(entry, "source")
    base = Map.get(entry, "base", "payloads")

    cond do
      not is_binary(source) or String.trim(source) == "" ->
        {:error, "build_context_upload_paths entry requires source"}

      base in ["skills_root", "mn_skills", "skills"] ->
        resolve_skills_root_source(source, config)

      base in ["workspace_root", "workspace", "repo_root"] ->
        resolve_workspace_root_source(source, config)

      true ->
        resolve_upload_source(source, Keyword.get(opts, :payloads_path))
    end
  end

  defp resolve_build_context_source(_entry, _config, _opts),
    do: {:error, "build_context_upload_paths entries must be objects"}

  defp resolve_skills_root_source(source, config) do
    environment = Map.get(config, "environment", %{})

    skills_root =
      Map.get(environment, "MN_SKILLS_ROOT") ||
        Map.get(environment, :MN_SKILLS_ROOT) ||
        Config.optional_string("MN_SKILLS_ROOT", :skills_root) ||
        System.get_env("MIRROR_NEURON_SKILLS_ROOT") ||
        System.get_env("OTTERDESK_MN_SKILLS_ROOT")

    if is_binary(skills_root) and String.trim(skills_root) != "" do
      root = Path.expand(skills_root)

      resolved =
        if Path.type(source) == :absolute do
          Path.expand(source)
        else
          Path.expand(source, root)
        end

      cond do
        not inside_path?(resolved, root) ->
          {:error,
           "build_context_upload_paths skills source must stay inside MN_SKILLS_ROOT: #{source}"}

        File.exists?(resolved) ->
          {:ok, resolved}

        true ->
          {:error, "build_context_upload_paths skills source does not exist: #{source}"}
      end
    else
      {:error, "build_context_upload_paths entry uses skills_root but MN_SKILLS_ROOT is not set"}
    end
  end

  defp resolve_workspace_root_source(source, config) do
    environment = Map.get(config, "environment", %{})

    workspace_root =
      Map.get(environment, "MN_WORKSPACE_ROOT") ||
        Map.get(environment, :MN_WORKSPACE_ROOT) ||
        Config.optional_string("MN_WORKSPACE_ROOT", :workspace_root)

    if is_binary(workspace_root) and String.trim(workspace_root) != "" do
      root = Path.expand(workspace_root)

      resolved =
        if Path.type(source) == :absolute do
          Path.expand(source)
        else
          Path.expand(source, root)
        end

      cond do
        not inside_path?(resolved, root) ->
          {:error,
           "build_context_upload_paths workspace source must stay inside MN_WORKSPACE_ROOT: #{source}"}

        File.exists?(resolved) ->
          {:ok, resolved}

        true ->
          {:error, "build_context_upload_paths workspace source does not exist: #{source}"}
      end
    else
      {:error,
       "build_context_upload_paths entry uses workspace_root but MN_WORKSPACE_ROOT is not set"}
    end
  end

  defp copy_upload_entry(source, target, coordinator_node, config, opts) do
    is_local = coordinator_node == Node.self()

    artifact_result =
      MirrorNeuron.Runner.Uploads.materialize_artifacts(source, target, config, opts)

    cond do
      is_local and File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp_r(source, target)
        |> case do
          {:ok, _files} -> artifact_upload_result(artifact_result)
          {:error, reason, _file} -> {:halt, {:error, inspect(reason)}}
        end

      is_local and File.exists?(source) ->
        File.mkdir_p!(Path.dirname(target))

        File.cp(source, target)
        |> case do
          :ok -> artifact_upload_result(artifact_result)
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end

      not is_local ->
        case copy_remote_upload(source, target, coordinator_node) do
          {:cont, :ok} -> artifact_upload_result(artifact_result)
          {:halt, {:error, _reason}} when artifact_result == :ok -> {:cont, :ok}
          other -> other
        end

      artifact_result == :ok ->
        {:cont, :ok}

      match?({:error, _reason}, artifact_result) ->
        {:error, reason} = artifact_result
        {:halt, {:error, reason}}

      true ->
        {:halt, {:error, "upload source does not exist locally: #{source}"}}
    end
  end

  defp artifact_upload_result(:ok), do: {:cont, :ok}
  defp artifact_upload_result(:not_found), do: {:cont, :ok}
  defp artifact_upload_result({:error, reason}), do: {:halt, {:error, reason}}

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

  defp docker_bin(config) do
    Map.get(config, "docker_bin") ||
      get_in(config, ["docker", "bin"]) ||
      Config.optional_string("MN_DOCKER_BIN", :docker_bin) ||
      System.find_executable("docker") ||
      "docker"
  end

  defp native_prep_enabled? do
    System.get_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  defp native_sandbox_prep_enabled?, do: native_prep_enabled?()

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
      _ -> Config.integer("MN_MAX_ARTIFACT_BYTES", :max_artifact_bytes)
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
    MirrorNeuron.Runner.Result.sanitize(result)
  end
end
