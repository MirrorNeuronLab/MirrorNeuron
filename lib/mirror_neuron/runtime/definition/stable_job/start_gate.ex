defmodule MirrorNeuron.Runtime.StableJob.StartGate do
  @moduledoc "Job-scoped fenced start leases with dead-local-owner reclamation."

  require Logger

  alias MirrorNeuron.JobData
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore

  @start_gate_ttl_ms 600_000
  @start_gate_retries 50
  @start_gate_retry_ms 100

  @doc false
  def with_start_gate(job_id, callback) do
    with :ok <- JobData.validate_id(job_id) do
      lease_name = "job-data-start:#{job_id}"
      owner_id = "#{NodeAdapter.self()}:#{inspect(self())}:#{System.unique_integer([:positive])}"

      case acquire_start_gate(lease_name, owner_id, @start_gate_retries) do
        {:ok, lease} ->
          try do
            callback.()
          after
            _ = RedisStore.release_fenced_lease(lease_name, owner_id, lease["epoch"])
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp acquire_start_gate(lease_name, owner_id, retries) do
    case RedisStore.acquire_fenced_lease(lease_name, owner_id, @start_gate_ttl_ms) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, {:locked, lease}} when retries > 0 ->
        reclaim_dead_local_start_gate(lease_name, lease)
        Process.sleep(@start_gate_retry_ms)
        acquire_start_gate(lease_name, owner_id, retries - 1)

      {:error, {:locked, _lease}} ->
        {:error, :job_data_start_queue_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reclaim_dead_local_start_gate(lease_name, %{"owner_id" => owner_id, "epoch" => epoch})
       when is_binary(owner_id) and is_integer(epoch) do
    case String.split(owner_id, ":", parts: 3) do
      [node, pid_text, nonce] ->
        with true <- node == to_string(NodeAdapter.self()),
             true <- Regex.match?(~r/^#PID<\d+\.\d+\.\d+>$/, pid_text),
             {_nonce, ""} <- Integer.parse(nonce),
             pid <-
               pid_text
               |> String.replace_prefix("#PID", "")
               |> String.to_charlist()
               |> :erlang.list_to_pid(),
             false <- Process.alive?(pid) do
          case RedisStore.release_fenced_lease(lease_name, owner_id, epoch) do
            :ok -> Logger.warning("reclaimed start gate left by a terminated local process")
            _ -> :ok
          end
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp reclaim_dead_local_start_gate(_lease_name, _lease), do: :ok
end
