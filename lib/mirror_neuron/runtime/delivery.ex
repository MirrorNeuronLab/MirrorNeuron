defmodule MirrorNeuron.Runtime.Delivery do
  @moduledoc false

  require Logger

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.DeliveryChannels

  @default_ttl_seconds 86_400
  @default_max_ttl_seconds 604_800
  @default_ack_receipt_ttl_seconds 3_600
  @default_stream_ttl_seconds 604_800
  @default_max_pending_per_agent 10_000
  @default_max_pending_per_job 100_000
  @default_lease_ms 30_000
  @default_lease_renew_ms 10_000
  @default_max_attempts 10
  @default_poll_ms 1_000
  @max_message_bytes 1_048_576
  @retry_base_ms 500
  @retry_max_ms 30_000
  @coordinator_agent_id "__mirror_neuron_job_coordinator__"
  @state_bearing_coordinator_events MapSet.new([
                                      "sandbox_job_completed",
                                      "agent_beacon_missed",
                                      "workflow_step_started",
                                      "workflow_step_completed",
                                      "workflow_step_partial",
                                      "workflow_step_skipped",
                                      "workflow_step_failed",
                                      "workflow_step_branch",
                                      "workflow_step_scatter",
                                      "workflow_graph_patch",
                                      "workflow_controller_checkpoint"
                                    ])

  def enqueue(job_id, agent_id, message, options \\ []) do
    normalized = normalize_message(job_id, agent_id, message)
    attempt_epoch = normalized |> Message.headers() |> Map.get("mn.attempt_epoch")
    ttl_ms = get_in(normalized, ["envelope", "ttl_ms"])
    now_ms = System.system_time(:millisecond)

    opts = [
      now_ms: now_ms,
      deadline_ms: now_ms + ttl_ms,
      pending_ttl_seconds: div(ttl_ms + 999, 1_000) + ack_receipt_ttl_seconds(),
      stream_ttl_seconds: stream_ttl_seconds(),
      max_pending_agent: max_pending_per_agent(),
      max_pending_job: max_pending_per_job()
    ]

    with :ok <- RedisStore.validate_job_attempt_epoch(job_id, attempt_epoch),
         {:ok, version} <- DeliveryChannels.version(job_id) do
      lane = DeliveryChannels.lane(agent_id, options)

      with :ok <- validate_message_bound(normalized, version),
           {:ok, limit} <- admission_limit(job_id, agent_id, version, lane, options) do
        RedisStore.enqueue_delivery(
          job_id,
          DeliveryChannels.bucket(agent_id, lane, version),
          normalized,
          opts
          |> Keyword.put(:max_pending_agent, limit)
          |> Keyword.put(
            :command_receipt_key,
            command_receipt_key(job_id, normalized, lane, version)
          )
        )
      end
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp validate_message_bound(message, 2) do
    if byte_size(Jason.encode!(message)) <= @max_message_bytes,
      do: :ok,
      else:
        {:error,
         {:message_payload_too_large, %{max_bytes: @max_message_bytes, use_artifacts: true}}}
  end

  defp validate_message_bound(_, _), do: :ok

  defp command_receipt_key(run_id, message, :command, 2) do
    case Message.headers(message)["mn.command_id"] do
      id when is_binary(id) -> MirrorNeuron.Runtime.CommandReceipts.storage_key(run_id, id)
      _ -> ""
    end
  end

  defp command_receipt_key(_, _, _, _), do: ""

  defp admission_limit(job_id, agent_id, 2, lane, options) when lane != :control do
    with {:ok, limit} <- DeliveryChannels.limit(job_id, agent_id, options),
         do: {:ok, min(max_pending_per_agent(), limit)}
  end

  defp admission_limit(_, _, _, _, _), do: {:ok, max_pending_per_agent()}

  def recover(job_id, agent_id, message) do
    message_id = Message.id(message)

    with {:ok, version} <- DeliveryChannels.version(job_id) do
      lanes = if version == 2, do: [:data, :command, :control], else: [:data]

      result =
        Enum.reduce_while(lanes, {:error, :not_found}, fn lane, _ ->
          case RedisStore.fetch_delivery_receipt(
                 job_id,
                 DeliveryChannels.bucket(agent_id, lane, version),
                 message_id
               ) do
            {:error, :not_found} = missing -> {:cont, missing}
            found -> {:halt, found}
          end
        end)

      case result do
        {:ok, _receipt} -> :ok
        {:error, :not_found} -> enqueue(job_id, agent_id, message) |> accepted()
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def report(job_id, agent_id, report_id, body, opts \\ []) do
    headers =
      case Keyword.get(opts, :attempt_epoch) do
        epoch when is_integer(epoch) -> %{"mn.attempt_epoch" => epoch}
        _epoch -> %{}
      end

    job_id
    |> Message.new(
      agent_id,
      @coordinator_agent_id,
      "runtime.agent_report",
      body,
      message_id: report_id,
      correlation_id: report_id,
      class: "control",
      headers: headers
    )
    |> then(&enqueue(job_id, @coordinator_agent_id, &1))
    |> accepted()
  end

  def coordinator_agent_id, do: @coordinator_agent_id

  def coordinator_event_requires_ack?(event_type),
    do: MapSet.member?(@state_bearing_coordinator_events, to_string(event_type))

  @doc false
  def stable_workflow_message(message) do
    update_in(message, ["envelope"], fn
      envelope when is_map(envelope) -> Map.delete(envelope, "attempt")
      envelope -> envelope
    end)
  end

  def read(job_id, agent_id, consumer, opts \\ []) do
    with {:ok, version} <- DeliveryChannels.version(job_id) do
      lanes =
        if version == 2,
          do: DeliveryChannels.read_order(agent_id, Keyword.get(opts, :command_streak, 0)),
          else: [:data]

      Enum.reduce_while(lanes, {:ok, []}, fn lane, _ ->
        bucket = DeliveryChannels.bucket(agent_id, lane, version)

        result =
          RedisStore.read_deliveries(job_id, bucket, consumer,
            lease_ms: if(Keyword.get(opts, :reclaim, false), do: 0, else: lease_ms()),
            claim_stale: Keyword.get(opts, :claim_stale, true),
            ensure_group: version == 2 or Keyword.get(opts, :ensure_group, true),
            strict_fifo: version == 2,
            max_attempts: max_attempts(),
            now_ms: System.system_time(:millisecond),
            count: Keyword.get(opts, :count, 1),
            stream_ttl_seconds: stream_ttl_seconds()
          )

        case result do
          {:ok, []} ->
            {:cont, {:ok, []}}

          {:ok, deliveries} ->
            {:halt,
             {:ok,
              Enum.map(
                deliveries,
                &Map.merge(&1, %{storage_agent_id: bucket, lane: lane, version: version})
              )}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  def defer(job_id, agent_id, consumer, delivery) do
    bucket = Map.get(delivery, :storage_agent_id, agent_id)

    with :ok <-
           MirrorNeuron.Persistence.DeliveryStore.defer_delivery(
             job_id,
             bucket,
             consumer,
             delivery
           ),
         :ok <-
           RedisStore.retry_delivery(
             job_id,
             bucket,
             consumer,
             delivery.stream_id,
             250,
             lease_ms()
           ),
         do: {:ok, 250}
  end

  def ack(job_id, agent_id, consumer, delivery) do
    RedisStore.ack_delivery(
      job_id,
      Map.get(delivery, :storage_agent_id, agent_id),
      consumer,
      delivery.stream_id,
      delivery.message_id,
      ack_receipt_ttl_seconds()
    )
  end

  def dead_letter(job_id, agent_id, delivery, reason) do
    MirrorNeuron.Runtime.Signals.resolve(job_id, agent_id, delivery.message_id, :terminal)
    MirrorNeuron.Runtime.Signals.error(job_id, agent_id, delivery.message_id, reason, :terminal)

    EventBus.publish(job_id, %{
      type: :dead_letter,
      agent_id: agent_id,
      message: Map.get(delivery, :message),
      payload: %{
        "reason" => inspect(reason),
        "message_id" => delivery.message_id,
        "attempt" => Map.get(delivery, :attempt, 0)
      },
      timestamp: MirrorNeuron.Runtime.timestamp()
    })

    RedisStore.dead_letter_delivery(
      job_id,
      Map.get(delivery, :storage_agent_id, agent_id),
      delivery.stream_id,
      delivery.message_id,
      reason,
      ack_receipt_ttl_seconds()
    )
  end

  def retry(job_id, agent_id, consumer, delivery) do
    delay_ms = retry_delay_ms(Map.get(delivery, :attempt, 1))

    case RedisStore.retry_delivery(
           job_id,
           Map.get(delivery, :storage_agent_id, agent_id),
           consumer,
           delivery.stream_id,
           delay_ms,
           lease_ms()
         ) do
      :ok -> {:ok, delay_ms}
      {:error, _reason} = error -> error
    end
  end

  def start_lease_renewer(job_id, agent_id, consumer, stream_id) do
    owner = self()
    token = make_ref()

    pid =
      spawn_link(fn ->
        monitor = Process.monitor(owner)

        renew_loop(
          owner,
          monitor,
          token,
          job_id,
          agent_id,
          consumer,
          stream_id,
          lease_renew_ms()
        )
      end)

    {pid, token}
  end

  def stop_lease_renewer({pid, token}, outcome \\ :stop) when is_pid(pid) do
    send(pid, {outcome, token})
    :ok
  end

  def expire_job(job_id), do: RedisStore.expire_job_deliveries(job_id, 60 * 60)

  def consumer_id(job_id, agent_id) do
    [
      to_string(Node.self()),
      job_id,
      agent_id,
      Integer.to_string(System.unique_integer([:positive]))
    ]
    |> Enum.join("/")
  end

  def default_ttl_seconds,
    do:
      config_integer(
        "MN_MESSAGE_DEFAULT_TTL_SECONDS",
        :message_default_ttl_seconds,
        @default_ttl_seconds
      )

  def max_ttl_seconds,
    do:
      config_integer(
        "MN_MESSAGE_MAX_TTL_SECONDS",
        :message_max_ttl_seconds,
        @default_max_ttl_seconds
      )

  def ack_receipt_ttl_seconds,
    do:
      config_integer(
        "MN_MESSAGE_ACK_RECEIPT_TTL_SECONDS",
        :message_ack_receipt_ttl_seconds,
        @default_ack_receipt_ttl_seconds
      )

  def stream_ttl_seconds,
    do:
      config_integer(
        "MN_MESSAGE_STREAM_TTL_SECONDS",
        :message_stream_ttl_seconds,
        @default_stream_ttl_seconds
      )

  def max_pending_per_agent,
    do:
      config_integer(
        "MN_MESSAGE_MAX_PENDING_PER_AGENT",
        :message_max_pending_per_agent,
        @default_max_pending_per_agent
      )

  def max_pending_per_job,
    do:
      config_integer(
        "MN_MESSAGE_MAX_PENDING_PER_JOB",
        :message_max_pending_per_job,
        @default_max_pending_per_job
      )

  def lease_ms,
    do:
      config_integer(
        "MN_MESSAGE_ACK_TIMEOUT_MS",
        :message_ack_timeout_ms,
        @default_lease_ms
      )

  def lease_renew_ms,
    do:
      config_integer(
        "MN_MESSAGE_LEASE_RENEW_MS",
        :message_lease_renew_ms,
        @default_lease_renew_ms
      )

  def max_attempts,
    do:
      config_integer(
        "MN_MESSAGE_DELIVERY_MAX_ATTEMPTS",
        :message_delivery_max_attempts,
        @default_max_attempts
      )

  def poll_ms,
    do:
      config_integer(
        "MN_MESSAGE_DELIVERY_POLL_MS",
        :message_delivery_poll_ms,
        @default_poll_ms
      )

  defp normalize_message(job_id, agent_id, message) do
    normalized = Message.normalize!(message, job_id: job_id, to: agent_id)

    if Message.job_id(normalized) != job_id do
      raise ArgumentError,
            "message job_id #{inspect(Message.job_id(normalized))} does not match #{inspect(job_id)}"
    end

    if Message.to(normalized) != agent_id do
      raise ArgumentError,
            "message target #{inspect(Message.to(normalized))} does not match #{inspect(agent_id)}"
    end

    ttl_ms =
      case get_in(normalized, ["envelope", "ttl_ms"]) do
        value when is_integer(value) and value > 0 ->
          value

        nil ->
          default_ttl_seconds() * 1_000

        value ->
          raise ArgumentError, "message ttl_ms must be a positive integer, got: #{inspect(value)}"
      end

    max_ttl_ms = max_ttl_seconds() * 1_000
    put_in(normalized, ["envelope", "ttl_ms"], min(ttl_ms, max_ttl_ms))
  end

  defp retry_delay_ms(attempt) do
    exponent = max(attempt - 1, 0)
    base = min(round(@retry_base_ms * :math.pow(2, exponent)), @retry_max_ms)
    jitter = max(div(base, 5), 1)
    max(base + :rand.uniform(jitter * 2 + 1) - jitter - 1, 0)
  end

  defp accepted({:ok, _receipt}), do: :ok
  defp accepted({:error, reason}), do: {:error, reason}

  defp config_integer(env_name, key, default) do
    value = System.get_env(env_name) || Application.get_env(:mirror_neuron, key, default)

    case value do
      integer when is_integer(integer) and integer > 0 ->
        integer

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {integer, ""} when integer > 0 -> integer
          _ -> default
        end

      _other ->
        default
    end
  end

  defp renew_loop(
         owner,
         monitor,
         token,
         job_id,
         agent_id,
         consumer,
         stream_id,
         interval_ms,
         failed? \\ false
       ) do
    receive do
      {:recovered, ^token} ->
        if failed?,
          do: MirrorNeuron.Runtime.Signals.resolve(job_id, signal_agent(agent_id), stream_id)

        :ok

      {:stop, ^token} ->
        :ok

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok
    after
      interval_ms ->
        failed? =
          case RedisStore.renew_delivery(job_id, agent_id, consumer, stream_id) do
            :ok ->
              if failed?,
                do:
                  MirrorNeuron.Runtime.Signals.resolve(job_id, signal_agent(agent_id), stream_id)

              false

            {:error, reason} ->
              MirrorNeuron.Runtime.Signals.error(
                job_id,
                signal_agent(agent_id),
                stream_id,
                {:delivery_lease_failed, reason}
              )

              Logger.warning("failed to renew message delivery lease: #{inspect(reason)}")
              true
          end

        renew_loop(
          owner,
          monitor,
          token,
          job_id,
          agent_id,
          consumer,
          stream_id,
          interval_ms,
          failed?
        )
    end
  end

  defp signal_agent(agent_id),
    do:
      agent_id
      |> String.replace_prefix("__mn_command__/", "")
      |> String.replace_prefix("__mn_control__/", "")
end
