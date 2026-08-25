defmodule MirrorNeuron.JobData do
  @moduledoc """
  Owns persistent, job-scoped filesystem data.

  The caller supplies only a validated `job_id`; host paths are always derived
  from `MN_JOB_DATA_ROOT` (default: `$MN_HOME/job-data`). A job directory is a
  direct child of that root and symlink job directories are rejected before
  initialization, reset, or deletion.
  """

  alias MirrorNeuron.Config

  @id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/

  def root do
    Config.string("MN_JOB_DATA_ROOT", :job_data_root)
    |> Path.expand()
  end

  def path(job_id) do
    with :ok <- validate_id(job_id) do
      {:ok, Path.join(root(), job_id)}
    end
  end

  def initialize(job_id, seed_paths \\ %{}) do
    with :ok <- prepare_root(),
         {:ok, job_path} <- path(job_id),
         :ok <- reject_symlink(job_path),
         :ok <- reject_existing_tree_symlinks(job_path),
         :ok <- File.mkdir_p(job_path),
         :ok <- seed_once(job_path, seed_paths),
         :ok <- reject_symlinks_in_tree(job_path, :job_data_symlink_not_allowed),
         :ok <- handoff_directory(job_path) do
      {:ok, job_path}
    end
  end

  def reset(job_id, seed_paths \\ %{}) do
    with :ok <- prepare_root(),
         {:ok, job_path} <- path(job_id),
         :ok <- reject_symlink(job_path),
         :ok <- remove_tree(job_path),
         :ok <- File.mkdir_p(job_path),
         :ok <- seed_once(job_path, seed_paths),
         :ok <- handoff_directory(job_path) do
      {:ok, job_path}
    end
  end

  def delete(job_id) do
    with :ok <- reject_symlink(root()),
         {:ok, job_path} <- path(job_id),
         :ok <- reject_symlink(job_path) do
      remove_tree(job_path)
    end
  end

  def validate_id(job_id) when is_binary(job_id) do
    if Regex.match?(@id_pattern, job_id) do
      :ok
    else
      {:error, :invalid_job_id}
    end
  end

  def validate_id(_job_id), do: {:error, :invalid_job_id}

  defp seed_once(job_path, seed_paths) when seed_paths in [%{}, nil],
    do: seed_once(job_path, %{".empty" => nil})

  defp seed_once(job_path, seed_paths) when is_map(seed_paths) do
    marker = Path.join(job_path, ".initialized")

    if File.exists?(marker) do
      :ok
    else
      normalized_seeds = Map.reject(seed_paths, fn {_name, source} -> is_nil(source) end)

      with :ok <- copy_seeds(job_path, normalized_seeds),
           :ok <- File.write(marker, "initialized\n", [:exclusive]) do
        :ok
      else
        {:error, :eexist} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp seed_once(_job_path, _seed_paths), do: {:error, :invalid_seed_paths}

  defp copy_seeds(job_path, seed_paths) do
    Enum.reduce_while(seed_paths, :ok, fn {name, source}, :ok ->
      destination = Path.join(job_path, to_string(name))

      with :ok <- validate_resource_path(name),
           true <- is_binary(source) and Path.type(source) == :absolute,
           true <- File.dir?(source),
           :ok <- reject_symlinks_in_tree(source, :seed_symlink_not_allowed),
           :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.cp_r(source, destination) |> copy_result(),
           :ok <- handoff_directory(destination) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:invalid_seed_path, name}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_result({:ok, _files}), do: :ok
  defp copy_result({:error, reason, file}), do: {:error, {reason, file}}

  defp validate_resource_path(name) do
    path = to_string(name)
    components = Path.split(path)

    if Path.type(path) == :relative and components != [] and
         Enum.all?(components, &Regex.match?(@id_pattern, &1)) do
      :ok
    else
      {:error, :invalid_resource_path}
    end
  end

  defp reject_existing_tree_symlinks(path) do
    if File.exists?(path),
      do: reject_symlinks_in_tree(path, :job_data_symlink_not_allowed),
      else: :ok
  end

  defp prepare_root do
    with :ok <- File.mkdir_p(root()) do
      reject_symlink(root())
    end
  end

  # Core commonly creates bind-mounted Job data as root in Docker while
  # stable native Job services run as the host user. Inherit the numeric owner
  # of the mount root's parent for only the Job directory and declared seed
  # roots. Contents are never traversed or reassigned.
  defp handoff_directory(path) do
    with {:ok, %File.Stat{uid: uid, gid: gid}} <- File.stat(Path.dirname(root())),
         {:ok, %File.Stat{} = stat} <- File.stat(path),
         :ok <- maybe_chown(path, stat.uid, uid),
         :ok <- maybe_chgrp(path, stat.gid, gid) do
      :ok
    end
  end

  defp maybe_chown(_path, owner, owner), do: :ok
  defp maybe_chown(path, _current, owner), do: File.chown(path, owner)

  defp maybe_chgrp(_path, group, group), do: :ok
  defp maybe_chgrp(path, _current, group), do: File.chgrp(path, group)

  defp reject_symlinks_in_tree(root, reason) do
    paths = [root | Path.wildcard(Path.join(root, "**/*"), match_dot: true)]

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, reason}}
        {:ok, _stat} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :job_data_symlink_not_allowed}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_tree(path) do
    case File.rm_rf(path) do
      {:ok, _files} -> :ok
      {:error, reason, file} -> {:error, {reason, file}}
    end
  end
end
