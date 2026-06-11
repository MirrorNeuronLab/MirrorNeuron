defmodule MirrorNeuron.Artifacts.JobStore do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Artifacts.BlobStore

  def root do
    System.get_env("MN_JOB_ARTIFACT_ROOT") ||
      Application.get_env(:mirror_neuron, :job_artifact_root) ||
      default_root()
  end

  def job_path(job_id) do
    with {:ok, job_id} <- normalize_job_id(job_id),
         root <- Path.expand(root()),
         path <- Path.expand(Path.join(root, job_id)),
         true <- inside_root?(path, root) and path != root do
      {:ok, path}
    else
      false -> {:error, "unsafe job artifact path for #{inspect(job_id)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_job_dir(job_id) do
    with {:ok, path} <- job_path(job_id),
         :ok <- File.mkdir_p(path) do
      {:ok, path}
    end
  end

  def materialize_blob(job_id, relative_path, source_path) do
    with {:ok, job_dir} <- ensure_job_dir(job_id),
         {:ok, destination} <- payload_destination(job_dir, relative_path, source_path),
         :ok <- BlobStore.materialize_file(source_path, destination) do
      {:ok, destination}
    end
  end

  def cleanup_job(job_id) do
    case job_path(job_id) do
      {:ok, path} ->
        case File.rm_rf(path) do
          {:ok, _files} ->
            :ok

          {:error, reason, file} ->
            Logger.warning(
              "failed to clean job artifacts for #{job_id} at #{file}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("skipping unsafe job artifact cleanup for #{inspect(job_id)}: #{reason}")
        {:error, reason}
    end
  end

  defp default_root do
    BlobStore.root()
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("jobs")
  end

  defp normalize_job_id(job_id) do
    job_id =
      job_id
      |> to_string()
      |> String.trim()

    cond do
      job_id == "" ->
        {:error, "job artifact cleanup requires a job id"}

      String.contains?(job_id, ["/", "\\"]) or job_id in [".", ".."] ->
        {:error, "job artifact id must be a single path segment"}

      true ->
        {:ok, job_id}
    end
  end

  defp payload_destination(job_dir, relative_path, source_path) do
    relative_path =
      relative_path
      |> normalize_relative_path()
      |> case do
        nil -> Path.basename(source_path)
        path -> path
      end

    safe_join(Path.join(job_dir, "payloads"), relative_path)
  end

  defp normalize_relative_path(nil), do: nil

  defp normalize_relative_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.trim()
    |> String.trim_leading("/")
    |> case do
      "" -> nil
      "." -> nil
      value -> value
    end
  end

  defp safe_join(root, relative_path) do
    root = Path.expand(root)

    cond do
      unsafe_relative_path?(relative_path) ->
        {:error, "unsafe artifact path #{inspect(relative_path)}"}

      true ->
        destination = Path.expand(Path.join(root, relative_path))

        if inside_root?(destination, root) do
          {:ok, destination}
        else
          {:error, "unsafe artifact path #{inspect(relative_path)}"}
        end
    end
  end

  defp unsafe_relative_path?(path) when not is_binary(path), do: true
  defp unsafe_relative_path?(""), do: true

  defp unsafe_relative_path?(path) do
    path = String.replace(path, "\\", "/")

    Path.type(path) == :absolute or
      path
      |> String.split("/", trim: true)
      |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
