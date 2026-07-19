defmodule MirrorNeuron.Persistence.DiskCheckpoint do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Config
  alias MirrorNeuron.Persistence.CheckpointLock

  @job_file "job.json"
  @agents_dir "agents"

  def with_job_lock(job_id, operation) when is_binary(job_id) and is_function(operation, 0) do
    if String.trim(job_id) == "" do
      {:error, :invalid_job_id}
    else
      with_encoded_job_lock(encoded_segment(job_id), operation)
    end
  end

  def with_job_lock(_job_id, _operation), do: {:error, :invalid_job_id}

  defp with_encoded_job_lock(encoded_job_id, operation) do
    resource = {__MODULE__, root(), encoded_job_id}
    process_key = {__MODULE__, :held_job_lock, resource}

    if Process.get(process_key) do
      operation.()
    else
      CheckpointLock.with_lock(resource, fn ->
        :global.trans({resource, self()}, fn ->
          Process.put(process_key, true)

          try do
            operation.()
          after
            Process.delete(process_key)
          end
        end)
      end)
    end
  end

  def root do
    base_root =
      Config.optional_string("MN_CHECKPOINT_ROOT", :checkpoint_root) ||
        Path.join(SharedStorage.root(), "checkpoints")

    namespace = Config.string("MN_REDIS_NAMESPACE", :redis_namespace)
    Path.join(base_root, encoded_segment(namespace))
  end

  def persist_job(job_id, job) when is_map(job) do
    with_job_lock(job_id, fn -> do_persist_job(job_id, job) end)
  end

  defp do_persist_job(job_id, job) do
    with {:ok, job_dir} <- ensure_job_dir(job_id),
         {:ok, encoded} <- Jason.encode(job),
         :ok <- atomic_write(Path.join(job_dir, @job_file), encoded) do
      :ok
    end
  end

  def persist_agent(job_id, agent_id, snapshot) when is_map(snapshot) do
    with_job_lock(job_id, fn -> do_persist_agent(job_id, agent_id, snapshot) end)
  end

  defp do_persist_agent(job_id, agent_id, snapshot) do
    with {:ok, job_dir} <- ensure_job_dir(job_id),
         :ok <- File.mkdir_p(Path.join(job_dir, @agents_dir)),
         {:ok, encoded} <- Jason.encode(snapshot),
         :ok <-
           atomic_write(
             Path.join([job_dir, @agents_dir, encoded_segment(agent_id) <> ".json"]),
             encoded
           ) do
      :ok
    end
  end

  def load_job(job_id) do
    with_job_lock(job_id, fn -> do_load_job(job_id) end)
  end

  defp do_load_job(job_id) do
    with {:ok, job_dir} <- job_dir(job_id),
         {:ok, encoded} <- File.read(Path.join(job_dir, @job_file)),
         {:ok, job} when is_map(job) <- Jason.decode(encoded) do
      {:ok, job}
    else
      {:ok, _other} -> {:error, :invalid_job_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_agents(job_id) do
    with_job_lock(job_id, fn -> do_load_agents(job_id) end)
  end

  defp do_load_agents(job_id) do
    with {:ok, job_dir} <- job_dir(job_id) do
      load_agents_path(job_dir)
    end
  end

  def list_jobs do
    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root(), &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()
        |> Enum.reduce(%{checkpoints: [], errors: []}, fn path, acc ->
          with_encoded_job_lock(Path.basename(path), fn ->
            case load_or_discard_orphan_checkpoint(path) do
              {:ok, checkpoint} ->
                Map.update!(acc, :checkpoints, &[checkpoint | &1])

              :orphan ->
                acc

              {:error, reason} ->
                if File.exists?(path) do
                  Map.update!(acc, :errors, &[{path, reason} | &1])
                else
                  acc
                end
            end
          end)
        end)
        |> then(fn result ->
          {:ok,
           %{
             checkpoints: Enum.reverse(result.checkpoints),
             errors: Enum.reverse(result.errors)
           }}
        end)

      {:error, :enoent} ->
        {:ok, %{checkpoints: [], errors: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def prune_agents(job_id, active_agent_ids) do
    with_job_lock(job_id, fn -> do_prune_agents(job_id, active_agent_ids) end)
  end

  defp do_prune_agents(job_id, active_agent_ids) do
    with {:ok, job_dir} <- job_dir(job_id) do
      expected =
        active_agent_ids
        |> Enum.map(&(encoded_segment(&1) <> ".json"))
        |> MapSet.new()

      job_dir
      |> Path.join(@agents_dir)
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in expected))
      |> Enum.each(&File.rm/1)

      cleanup_temp_files(job_dir)
      :ok
    end
  end

  def delete_job(job_id) do
    with_job_lock(job_id, fn -> do_delete_job(job_id) end)
  end

  defp do_delete_job(job_id) do
    with {:ok, path} <- job_dir(job_id) do
      case File.rm_rf(path) do
        {:ok, _files} -> sync_directory(Path.dirname(path))
        {:error, reason, file} -> {:error, {file, reason}}
      end
    end
  end

  defp load_checkpoint_path(path) do
    with {:ok, job} <- read_map(Path.join(path, @job_file)),
         job_id when is_binary(job_id) and job_id != "" <- Map.get(job, "job_id"),
         {:ok, agents} <- load_agents_path(path) do
      {:ok, %{job: job, agents: agents}}
    else
      nil -> {:error, :missing_job_id}
      "" -> {:error, :missing_job_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_or_discard_orphan_checkpoint(path) do
    job_path = Path.join(path, @job_file)

    case File.stat(job_path) do
      {:ok, %File.Stat{type: :regular}} ->
        load_checkpoint_path(path)

      {:ok, _other} ->
        {:error, :invalid_checkpoint}

      {:error, :enoent} ->
        case File.rm_rf(path) do
          {:ok, _files} ->
            sync_directory(Path.dirname(path))
            :orphan

          {:error, reason, file} ->
            {:error, {file, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_agents_path(job_dir) do
    job_dir
    |> Path.join(@agents_dir)
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, agents} ->
      case read_map(path) do
        {:ok, agent} -> {:cont, {:ok, [agent | agents]}}
        {:error, reason} -> {:halt, {:error, {Path.basename(path), reason}}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.reverse(agents)}
      error -> error
    end
  end

  defp read_map(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(encoded) do
      {:ok, value}
    else
      {:ok, _other} -> {:error, :invalid_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_job_dir(job_id) do
    with {:ok, path} <- job_dir(job_id),
         :ok <- File.mkdir_p(path) do
      {:ok, path}
    end
  end

  defp job_dir(job_id) when is_binary(job_id) and job_id != "",
    do: {:ok, Path.join(root(), encoded_segment(job_id))}

  defp job_dir(_job_id), do: {:error, :invalid_job_id}

  defp encoded_segment(value) do
    value
    |> to_string()
    |> Base.url_encode64(padding: false)
  end

  defp atomic_write(path, contents) do
    temp_path = "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, file} <- File.open(temp_path, [:write, :binary, :exclusive]),
         :ok <- write_and_sync(file, contents),
         :ok <- File.rename(temp_path, path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, reason}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, directory} ->
        _ = :file.sync(directory)
        _ = :file.close(directory)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp write_and_sync(file, contents) do
    result =
      with :ok <- IO.binwrite(file, contents),
           :ok <- :file.sync(file) do
        :ok
      end

    close_result = File.close(file)

    case {result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp cleanup_temp_files(job_dir) do
    job_dir
    |> Path.join("**/*.tmp.*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      case File.rm(path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("failed to remove checkpoint temp file #{path}: #{inspect(reason)}")
      end
    end)
  end
end
