defmodule MirrorNeuron.Runner.DockerWorker.Preparation do
  @moduledoc "Validates SDK-prepared images and runtime models without building or allocating resources."

  alias MirrorNeuron.Runner.DockerWorker.Observations
  alias MirrorNeuron.Runner.DockerWorker.Settings

  @prepared_model_env_vars [
    "MN_NODE_RUNTIME_MODELS",
    "MN_NODE_MODELS",
    "MN_DOCKER_MODEL_RUNNER_MODEL",
    "MN_LLM_MODEL_RUNNER_MODEL"
  ]

  def resolve_image(config, base_dir, opts) do
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

  defp build_worker_image(_base_dir, _build_source, _image, _config, _opts) do
    {:error,
     "docker_worker image build is owned by mn-python-sdk/API/CLI; submit a prepared image via config.image or config.docker.image instead of docker_worker_image/build"}
  end

  def ensure_docker_model_runner_model(config, opts) do
    env = Settings.extra_env(config)
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
        Observations.emit_runner_event(opts, "docker_worker_model_prepare_deferred", %{
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
        Observations.emit_runner_event(opts, "docker_worker_model_not_prepared", %{
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
    do: env |> Map.get("MN_RUNTIME_MODEL_MANAGED") |> Settings.truthy?()

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

  def reject_published_ports(config) do
    docker = Map.get(config, "docker", %{})

    cond do
      Settings.nonempty?(Map.get(config, "publish_ports")) ->
        {:error,
         "docker_worker does not publish host ports; use BEAM/core messaging or declared service ports"}

      Settings.nonempty?(Map.get(docker, "publish_ports")) ->
        {:error,
         "docker_worker does not publish host ports; use BEAM/core messaging or declared service ports"}

      Settings.nonempty?(Map.get(docker, "ports")) ->
        {:error,
         "docker_worker does not publish host ports; use BEAM/core messaging or declared service ports"}

      true ->
        :ok
    end
  end
end
