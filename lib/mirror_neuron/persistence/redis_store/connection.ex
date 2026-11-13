defmodule MirrorNeuron.Persistence.RedisStore.Connection do
  @moduledoc "Redis commands, transactions, reconnects and replication confirmation."

  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  @doc """
  Return the opaque identity and writable-primary state of the Redis plane.

  The identity is created once in the configured namespace and replicated by
  Redis. A process connected directly to a replica can read the identity, but
  is never reported as a writable runtime endpoint.
  """
  def coordination_store_status do
    identity_key = Keys.key("coordination-store", "identity")

    with {:ok, role_reply} <- command(["ROLE"]),
         role <- redis_role(role_reply),
         {:ok, identity} <- coordination_store_identity(identity_key, role) do
      writable_primary = role == "master"

      {:ok,
       %{
         "identity" => identity,
         "namespace" => Keys.namespace(),
         "role" => role,
         "writable_primary" => writable_primary,
         "healthy" => identity != "" and writable_primary
       }}
    else
      {:error, reason} ->
        {:error, {:coordination_store_unavailable, reason}}
    end
  end

  def maybe_wait_for_deleted_keys(0), do: :ok

  def maybe_wait_for_deleted_keys(_deleted), do: wait_for_replicas()

  def expire_key(_redis_key, ttl_seconds) when not is_integer(ttl_seconds) or ttl_seconds <= 0,
    do: :ok

  def expire_key(redis_key, ttl_seconds) do
    _ = command(["EXPIRE", redis_key, to_string(ttl_seconds)])
    :ok
  end

  def persist_key(redis_key) do
    _ = command(["PERSIST", redis_key])
    :ok
  end

  defp coordination_store_identity(identity_key, "master") do
    candidate =
      24
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    with {:ok, _result} <- command(["SET", identity_key, candidate, "NX"]),
         {:ok, identity} when is_binary(identity) and identity != "" <-
           command(["GET", identity_key]),
         {:ok, "OK"} <- command(["SET", identity_key, identity, "XX"]) do
      {:ok, identity}
    else
      {:ok, nil} -> {:error, :coordination_store_identity_missing}
      {:ok, other} -> {:error, {:invalid_coordination_store_identity, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coordination_store_identity(identity_key, role)
       when role in ["slave", "replica"] do
    case command(["GET", identity_key]) do
      {:ok, identity} when is_binary(identity) and identity != "" -> {:ok, identity}
      {:ok, _missing} -> {:error, :coordination_store_identity_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coordination_store_identity(_identity_key, role),
    do: {:error, {:unsupported_redis_role, role}}

  defp redis_role([role | _]) when is_binary(role), do: String.downcase(role)

  defp redis_role(other), do: "unknown:#{inspect(other)}"

  def command(args), do: command(args, redis_reconnect_attempts(), redis_reconnect_backoff_ms())

  def command(args, attempts_left, backoff_ms),
    do: command_local(args, attempts_left, backoff_ms)

  defp command_local(args, attempts_left, backoff_ms) do
    connection = redis_connection()

    case safe_command(connection || MirrorNeuron.Redis.Connection, args) do
      {:error, reason} = error ->
        cond do
          reconnectable_error?(reason) and attempts_left > 0 ->
            _ = MirrorNeuron.Redis.reconnect(connection)
            Process.sleep(backoff_ms)
            command_local(args, attempts_left - 1, next_reconnect_backoff(backoff_ms))

          readonly_error?(reason) ->
            {:error, {:redis_primary_unavailable, reason}}

          true ->
            error
        end

      other ->
        other
    end
  end

  defp readonly_error?(%Redix.Error{message: message}) when is_binary(message) do
    message
    |> String.upcase()
    |> String.contains?("READONLY")
  end

  defp readonly_error?(_reason), do: false

  defp safe_command(connection, args) do
    Redix.command(connection, args)
  catch
    :exit, {:redix_exited_during_call, reason} ->
      {:error, {:redix_exited_during_call, reason}}

    :exit, {:noproc, _} = reason ->
      {:error, {:redix_exit, reason}}

    :exit, reason ->
      {:error, {:redix_exit, reason}}
  end

  def transaction(commands),
    do: transaction(commands, redis_reconnect_attempts(), redis_reconnect_backoff_ms())

  def transaction(commands, attempts_left, backoff_ms) do
    transaction_commands = [["MULTI"] | commands] ++ [["EXEC"]]

    case pipeline(transaction_commands, attempts_left, backoff_ms) do
      {:ok, results} ->
        Results.parse_transaction_results(results)

      {:error, _reason} = error ->
        error
    end
  end

  def pipeline(commands),
    do: pipeline(commands, redis_reconnect_attempts(), redis_reconnect_backoff_ms())

  def pipeline(commands, attempts_left, backoff_ms),
    do: pipeline_local(commands, attempts_left, backoff_ms)

  defp pipeline_local(commands, attempts_left, backoff_ms) do
    connection = redis_connection()

    case safe_pipeline(connection || MirrorNeuron.Redis.Connection, commands) do
      {:ok, results} ->
        case readonly_error_in_results(results) do
          nil ->
            {:ok, results}

          reason ->
            retry_or_primary_unavailable(
              commands,
              attempts_left,
              backoff_ms,
              reason,
              connection
            )
        end

      {:error, reason} = error ->
        cond do
          reconnectable_error?(reason) and attempts_left > 0 ->
            _ = MirrorNeuron.Redis.reconnect(connection)
            Process.sleep(backoff_ms)
            pipeline_local(commands, attempts_left - 1, next_reconnect_backoff(backoff_ms))

          readonly_error?(reason) ->
            {:error, {:redis_primary_unavailable, reason}}

          true ->
            error
        end
    end
  end

  defp readonly_error_in_results(results) when is_list(results) do
    Enum.find(results, &readonly_error?/1)
  end

  defp readonly_error_in_results(_results), do: nil

  defp retry_or_primary_unavailable(
         commands,
         attempts_left,
         backoff_ms,
         _reason,
         failed_connection
       )
       when attempts_left > 0 do
    _ = MirrorNeuron.Redis.reconnect(failed_connection)
    Process.sleep(backoff_ms)
    pipeline_local(commands, attempts_left - 1, next_reconnect_backoff(backoff_ms))
  end

  defp retry_or_primary_unavailable(
         _commands,
         _attempts_left,
         _backoff_ms,
         reason,
         _failed_connection
       ),
       do: {:error, {:redis_primary_unavailable, reason}}

  defp safe_pipeline(connection, commands) do
    Redix.pipeline(connection, commands)
  catch
    :exit, {:redix_exited_during_call, reason} ->
      {:error, {:redix_exited_during_call, reason}}

    :exit, {:noproc, _} = reason ->
      {:error, {:redix_exit, reason}}

    :exit, reason ->
      {:error, {:redix_exit, reason}}
  end

  def scan_keys(pattern), do: scan_keys(pattern, "0", [])

  def scan_keys(pattern, cursor, acc) do
    case command(["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [next_cursor, keys]} ->
        next_acc = acc ++ keys

        if next_cursor == "0" do
          {:ok, next_acc}
        else
          scan_keys(pattern, next_cursor, next_acc)
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp reconnectable_error?(reason), do: MirrorNeuron.Redis.reconnectable_error?(reason)

  defp redis_connection, do: Process.whereis(MirrorNeuron.Redis.Connection)

  defp redis_reconnect_attempts do
    Values.config_integer("MN_REDIS_RECONNECT_ATTEMPTS", :redis_reconnect_attempts, 10)
  end

  defp redis_reconnect_backoff_ms do
    Values.config_integer("MN_REDIS_RECONNECT_BACKOFF_MS", :redis_reconnect_backoff_ms, 250)
  end

  defp redis_reconnect_max_backoff_ms do
    Values.config_integer(
      "MN_REDIS_RECONNECT_MAX_BACKOFF_MS",
      :redis_reconnect_max_backoff_ms,
      2_000
    )
  end

  defp next_reconnect_backoff(backoff_ms) do
    min(backoff_ms * 2, redis_reconnect_max_backoff_ms())
  end

  def wait_for_replicas do
    wait_replicas = Values.config_integer("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas, 0)

    wait_timeout_ms =
      Values.config_integer("MN_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms, 100)

    cond do
      wait_replicas <= 0 ->
        :ok

      true ->
        case command(["WAIT", to_string(wait_replicas), to_string(wait_timeout_ms)]) do
          {:ok, acknowledgements}
          when is_integer(acknowledgements) and acknowledgements >= wait_replicas ->
            :ok

          {:ok, acknowledgements} ->
            {:error, {:redis_replication_wait_timeout, acknowledgements, wait_replicas}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
