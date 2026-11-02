defmodule MirrorNeuron.Runtime.CommandReceipts do
  @moduledoc "Correlated command acceptance and declared-boundary completion receipts."
  alias MirrorNeuron.Persistence.RedisStore, as: Store
  alias MirrorNeuron.Persistence.ProtectedRedis
  alias MirrorNeuron.Runtime.{Signals, ErrorEnvelope}

  def prepare(run_id, command_id, input_id, payload, declaration) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({input_id, payload})) |> Base.encode16()

    receipt = %{
      "run_id" => run_id,
      "command_id" => command_id,
      "input_id" => input_id,
      "digest" => digest,
      "status" => "pending_admission",
      "accepted" => false,
      "completion_agent" => declaration["completion_agent"],
      "entrypoint" => declaration["entrypoint"],
      "revision" => 0,
      "updated_at" => MirrorNeuron.Runtime.timestamp()
    }

    script = """
    local old = redis.call('get', KEYS[1])
    if old then
      if cjson.decode(old).digest ~= ARGV[2] then return {'conflict'} end
      return {'ok', old}
    end
    redis.call('zremrangebyscore', KEYS[2], '-inf', ARGV[3])
    if redis.call('zcard', KEYS[2]) >= 10000 then return {'full'} end
    redis.call('set', KEYS[1], ARGV[1], 'EX', 604800)
    redis.call('zadd', KEYS[2], tonumber(ARGV[3]) + 604800, KEYS[1])
    redis.call('expire', KEYS[2], 604800)
    redis.call('sadd', KEYS[3], KEYS[1], KEYS[2])
    redis.call('expire', KEYS[3], 604800)
    return {'ok', ARGV[1]}
    """

    case ProtectedRedis.command("responses", [
           "EVAL",
           script,
           "3",
           key(run_id, command_id),
           Store.storage_key(["job", run_id, "commands"]),
           Store.storage_key(["job", run_id, "delivery_keys"]),
           Jason.encode!(receipt),
           digest,
           to_string(System.system_time(:second))
         ]) do
      {:ok, ["ok", encoded]} ->
        with :ok <- ProtectedRedis.barrier("responses"), do: Jason.decode(encoded)

      {:ok, ["conflict"]} ->
        {:error, :request_conflict}

      {:ok, ["full"]} ->
        {:error,
         {:retry_later,
          %{
            "accepted" => false,
            "command_id" => command_id,
            "scope" => "responses",
            "retry_after_ms" => 1000
          }}}

      error ->
        error
    end
  end

  def get(run_id, command_id) do
    with {:ok, encoded} when is_binary(encoded) <-
           ProtectedRedis.command("responses", ["GET", key(run_id, command_id)]),
         {:ok, receipt} <- Jason.decode(encoded),
         {:ok, receipt} <- reconcile_acceptance(run_id, command_id, receipt),
         {:ok, receipt} <- reconcile_terminal_run(run_id, command_id, receipt),
         :ok <- ProtectedRedis.confirm_snapshot("responses") do
      {:ok, public(receipt)}
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp reconcile_acceptance(run_id, id, %{"accepted" => false, "entrypoint" => agent} = receipt)
       when is_binary(agent) do
    with {:ok, version} <- MirrorNeuron.Runtime.DeliveryChannels.version(run_id) do
      bucket = MirrorNeuron.Runtime.DeliveryChannels.bucket(agent, :command, version)

      case Store.fetch_delivery_receipt(run_id, bucket, id) do
        {:ok, _delivery} ->
          with {:ok, event} <- update(run_id, id, "accepted") do
            {:ok, Map.merge(receipt, event["payload"])}
          end

        {:error, :not_found} ->
          {:ok, receipt}

        error ->
          error
      end
    end
  end

  defp reconcile_acceptance(_, _, receipt), do: {:ok, receipt}

  defp reconcile_terminal_run(run_id, id, %{"accepted" => true, "status" => status} = receipt)
       when status in ["accepted", "executing"] do
    case Store.fetch_job(run_id) do
      {:ok, %{"status" => run_status}} when run_status in ["completed", "failed", "cancelled"] ->
        terminal = if run_status == "cancelled", do: "cancelled", else: "interrupted"

        with {:ok, event} <- update(run_id, id, terminal, "__runtime__"),
             do: {:ok, Map.merge(receipt, event["payload"])}

      {:ok, _} ->
        {:ok, receipt}

      error ->
        error
    end
  end

  defp reconcile_terminal_run(_, _, receipt), do: {:ok, receipt}

  def settle_run_async(run_id) do
    result =
      Task.Supervisor.start_child(MirrorNeuron.Runtime.SignalTaskSupervisor, fn ->
        # Bounded by the admission cap; get reconciles only against persisted lifecycle.
        with {:ok, keys} <-
               ProtectedRedis.command("responses", [
                 "ZRANGE",
                 Store.storage_key(["job", run_id, "commands"]),
                 "0",
                 "9999"
               ]) do
          Enum.each(keys, fn key ->
            with {:ok, encoded} when is_binary(encoded) <-
                   ProtectedRedis.command("responses", ["GET", key]),
                 {:ok, receipt} <- Jason.decode(encoded),
                 {:ok, _} <- get(run_id, receipt["command_id"]) do
              :ok
            else
              {:ok, nil} -> :ok
              _ -> Signals.delivery_unavailable(run_id, "responses")
            end
          end)
        else
          _ -> Signals.delivery_unavailable(run_id, "responses")
        end
      end)

    if match?({:error, _}, result), do: Signals.delivery_unavailable(run_id, "responses")
    result
  catch
    :exit, _ -> Signals.delivery_unavailable(run_id, "responses")
  end

  def update(run_id, command_id, status, agent_id \\ "", result \\ nil) do
    script = """
    local old = redis.call('get', KEYS[1])
    if not old then return {'missing'} end
    local record = cjson.decode(old)
    local terminal = {completed=true, failed=true, cancelled=true, expired=true, interrupted=true}
    if terminal[record.status] then return {'ok', old} end
    if ARGV[1] == 'accepted' and record.accepted then return {'ok', old} end
    if ARGV[1] == 'not_accepted' and record.accepted then return {'ok', old} end
    if ARGV[1] ~= 'accepted' and ARGV[1] ~= 'not_accepted' then
      local lifecycle = ARGV[2] == '__runtime__' and (ARGV[1] == 'cancelled' or ARGV[1] == 'interrupted')
      if not lifecycle and record.completion_agent ~= ARGV[2] then return {'boundary'} end
    end
    if record.status == "executing" and ARGV[1] == "accepted" then return {"ok", old} end
    record.revision = (record.revision or 0) + 1
    record.status = ARGV[1]
    record.accepted = ARGV[1] ~= 'not_accepted'
    record.updated_at = ARGV[3]
    if ARGV[4] ~= '' then record.result = cjson.decode(ARGV[4]) end
    local encoded = cjson.encode(record)
    redis.call('set', KEYS[1], encoded, 'KEEPTTL')
    return {'ok', encoded}
    """

    encoded = if is_nil(result), do: "", else: Jason.encode!(result)

    if byte_size(encoded) > 16_384 do
      {:error, :command_response_too_large}
    else
      with {:ok, ["ok", saved]} <-
             ProtectedRedis.command("responses", [
               "EVAL",
               script,
               "1",
               key(run_id, command_id),
               status,
               agent_id,
               MirrorNeuron.Runtime.timestamp(),
               encoded
             ]),
           :ok <- ProtectedRedis.barrier("responses"),
           {:ok, receipt} <- Jason.decode(saved) do
        public = public(receipt)

        Signals.publish(
          run_id,
          "responses",
          %{
            "type" => "runtime.command_#{receipt["status"]}",
            "run_id" => run_id,
            "payload" => public,
            "level" => if(status == "failed", do: "error", else: "info")
          },
          command_id
        )
      else
        {:ok, ["boundary"]} -> :not_boundary
        {:ok, ["missing"]} -> {:error, :not_found}
        error -> error
      end
    end
  end

  def complete(message, state, response \\ nil) do
    command_id = MirrorNeuron.Message.headers(message)["mn.command_id"]

    if is_binary(command_id) do
      result = response || Map.get(state.local_state, :last_output_payload)
      result = if is_map(result), do: result, else: %{"handled" => true}

      with {:ok, result} <- bounded_result(result, state) do
        update(state.job_id, command_id, "completed", state.node.node_id, result)
      end
    else
      :not_boundary
    end
  end

  def fail(%{"envelope" => _} = message, state, reason) do
    case MirrorNeuron.Message.headers(message)["mn.command_id"] do
      id when is_binary(id) ->
        update(state.job_id, id, "failed", state.node.node_id, %{
          "error" => ErrorEnvelope.normalize(reason)
        })

      _ ->
        :not_boundary
    end
  end

  def fail(_, _, _), do: :not_boundary

  def executing(message, state) do
    case MirrorNeuron.Message.headers(message)["mn.command_id"] do
      id when is_binary(id) -> update(state.job_id, id, "executing", state.node.node_id)
      _ -> :not_boundary
    end
  end

  defp bounded_result(result, state) do
    if byte_size(Jason.encode!(result)) <= 16_384 do
      {:ok, result}
    else
      with {:ok, job} <- Store.fetch_job(state.job_id),
           {:ok, ref} <-
             MirrorNeuron.Artifacts.StagedArtifact.stage_from_manifest(result, job["manifest"],
               run_id: state.job_id,
               kind: "command_response"
             ) do
        {:ok, %{"result_ref" => ref}}
      end
    end
  end

  defp public(receipt) do
    receipt
    |> Map.drop(["digest", "completion_agent", "entrypoint"])
    |> then(fn record ->
      if record["status"] == "pending_admission",
        do: Map.put(record, "accepted", nil),
        else: record
    end)
    |> Map.put("observed_at", MirrorNeuron.Runtime.timestamp())
  end

  @doc false
  def storage_key(run_id, command_id), do: key(run_id, command_id)

  defp key(run_id, command_id),
    do:
      Store.storage_key(["job", run_id, "command", Base.url_encode64(command_id, padding: false)])
end
