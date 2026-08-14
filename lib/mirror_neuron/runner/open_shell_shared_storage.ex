defmodule MirrorNeuron.Runner.OpenShellSharedStorage do
  @moduledoc false

  alias MirrorNeuron.Config
  alias MirrorNeuron.Sandbox.OpenShellCLI

  defstruct enabled: false,
            config: %{},
            payload: %{},
            opts: [],
            local_root: nil,
            remote_root: nil

  def plan(payload, config, remote_dir, opts) do
    if Map.get(config, "sync_shared_storage", false) == true do
      build_plan(payload, config, remote_dir, opts)
    else
      {:ok, %__MODULE__{config: config, payload: payload, opts: opts}}
    end
  end

  def upload(plan, executable, runner \\ &system_command/2)

  def upload(%__MODULE__{enabled: false}, _executable, _runner),
    do: :ok

  def upload(%__MODULE__{} = plan, executable, runner) do
    plan.local_root
    |> upload_sources()
    |> Enum.reduce_while(:ok, fn source, :ok ->
      args = [
        "sandbox",
        "upload",
        plan.config["sandbox_name"],
        source,
        plan.remote_root,
        "--no-git-ignore"
      ]

      case runner.(executable, args) do
        {_output, 0} ->
          {:cont, :ok}

        {output, exit_code} ->
          {:halt,
           {:error,
            %{
              "error" => "failed to upload shared storage to OpenShell sandbox",
              "source" => source,
              "remote_root" => plan.remote_root,
              "exit_code" => exit_code,
              "logs" => output
            }}}
      end
    end)
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  def download(plan, executable, runner \\ &system_command/2)

  def download(%__MODULE__{enabled: false}, _executable, _runner),
    do: :ok

  def download(%__MODULE__{} = plan, executable, runner) do
    temp_dir =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_openshell_shared_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)

    try do
      args = [
        "sandbox",
        "download",
        plan.config["sandbox_name"],
        Path.join(plan.remote_root, "outputs"),
        temp_dir
      ]

      case runner.(executable, args) do
        {_output, 0} ->
          merge_tree(temp_dir, Path.join(plan.local_root, "outputs"))

        {output, exit_code} ->
          {:error,
           %{
             "error" => "failed to download shared storage from OpenShell sandbox",
             "remote_root" => plan.remote_root,
             "exit_code" => exit_code,
             "logs" => output
           }}
      end
    after
      File.rm_rf(temp_dir)
    end
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  def system_command(executable, args) do
    System.cmd(executable, args,
      stderr_to_stdout: true,
      env: OpenShellCLI.command_env()
    )
  end

  defp build_plan(payload, config, remote_dir, opts) do
    environment =
      case Map.get(config, "environment", %{}) do
        value when is_map(value) -> value
        _other -> %{}
      end

    raw_local_root =
      environment
      |> Map.get("MN_JOB_SHARED_STORAGE_ROOT", "")
      |> to_string()
      |> String.trim()

    local_root = Path.expand(raw_local_root)

    runtime_root =
      Config.string("MN_SHARED_STORAGE_ROOT", :shared_storage_root)
      |> Path.expand()

    cond do
      raw_local_root == "" ->
        {:error, "sync_shared_storage requires environment.MN_JOB_SHARED_STORAGE_ROOT"}

      not inside_path?(local_root, runtime_root) ->
        {:error,
         "OpenShell shared storage must stay inside the runtime shared root: #{local_root}"}

      not File.dir?(local_root) ->
        {:error, "OpenShell shared storage root does not exist: #{local_root}"}

      not File.dir?(Path.join(local_root, "outputs")) ->
        {:error, "OpenShell shared storage outputs directory does not exist: #{local_root}"}

      true ->
        invocation =
          opts
          |> Keyword.get(:invocation, 1)
          |> to_string()
          |> sanitize_path_segment()

        attempt =
          opts
          |> Keyword.get(:attempt, 1)
          |> to_string()
          |> sanitize_path_segment()

        remote_root =
          Path.join([remote_dir, ".mn-shared", "i#{invocation}-a#{attempt}"])

        rewrite = fn value -> rewrite_value(value, local_root, remote_root) end

        {:ok,
         %__MODULE__{
           enabled: true,
           config:
             config
             |> rewrite.()
             |> Map.put("sandbox_name", config["sandbox_name"]),
           payload: rewrite.(payload),
           opts: rewrite.(opts),
           local_root: local_root,
           remote_root: remote_root
         }}
    end
  end

  defp upload_sources(local_root) do
    ["inputs", "outputs"]
    |> Enum.map(&Path.join(local_root, &1))
    |> Enum.filter(&File.exists?/1)
  end

  defp rewrite_value(value, local_root, remote_root) when is_binary(value),
    do: String.replace(value, local_root, remote_root)

  defp rewrite_value(value, local_root, remote_root) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {key, rewrite_value(nested, local_root, remote_root)}
    end)
  end

  defp rewrite_value(value, local_root, remote_root) when is_list(value),
    do: Enum.map(value, &rewrite_value(&1, local_root, remote_root))

  defp rewrite_value({key, value}, local_root, remote_root),
    do: {key, rewrite_value(value, local_root, remote_root)}

  defp rewrite_value(value, _local_root, _remote_root), do: value

  defp merge_tree(source, target) do
    with {:ok, entries} <- File.ls(source),
         :ok <- File.mkdir_p(target) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        child_source = Path.join(source, entry)
        child_target = Path.join(target, entry)

        case File.lstat(child_source) do
          {:ok, %File.Stat{type: :directory}} ->
            case merge_tree(child_source, child_target) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end

          {:ok, %File.Stat{type: :regular}} ->
            File.mkdir_p!(Path.dirname(child_target))

            case File.cp(child_source, child_target) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, %File.Stat{type: type}} ->
            {:halt, {:error, "unsupported OpenShell output file type: #{type}"}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp inside_path?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp sanitize_path_segment(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.trim(".-")
    |> case do
      "" -> "1"
      normalized -> normalized
    end
  end
end
