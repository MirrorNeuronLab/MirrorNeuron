defmodule MirrorNeuron.Runtime.Backpressure do
  @moduledoc false

  @default_max_queue_depth 100
  @default_high_watermark 75
  @default_low_watermark 25
  @default_retry_after_ms 250

  def snapshot(agent_id, node, queue_depth, opts \\ [], previous \\ nil) do
    config = config(node, opts)
    queue_depth = max(as_int(queue_depth, 0), 0)
    status = status(queue_depth, config, previous)

    %{
      "agent_id" => agent_id,
      "queue_depth" => queue_depth,
      "max_queue_depth" => config.max_queue_depth,
      "high_watermark" => config.high_watermark,
      "low_watermark" => config.low_watermark,
      "retry_after_ms" => config.retry_after_ms,
      "backpressure" => status in ["pressured", "saturated"],
      "status" => status
    }
  end

  def config(node_or_config, opts \\ []) do
    raw =
      node_or_config
      |> raw_config()
      |> Map.merge(Map.new(opts))

    max_queue_depth =
      raw
      |> Map.get("max_queue_depth", Map.get(raw, :max_queue_depth, default_max_queue_depth()))
      |> as_int(default_max_queue_depth())
      |> max(1)

    high_watermark =
      raw
      |> Map.get(
        "high_watermark",
        Map.get(raw, :high_watermark, default_high_watermark(max_queue_depth))
      )
      |> as_int(default_high_watermark(max_queue_depth))
      |> min(max_queue_depth)
      |> max(1)

    low_watermark =
      raw
      |> Map.get(
        "low_watermark",
        Map.get(raw, :low_watermark, default_low_watermark(high_watermark))
      )
      |> as_int(default_low_watermark(high_watermark))
      |> min(high_watermark)
      |> max(0)

    retry_after_ms =
      raw
      |> Map.get("retry_after_ms", Map.get(raw, :retry_after_ms, @default_retry_after_ms))
      |> as_int(@default_retry_after_ms)
      |> max(0)

    %{
      max_queue_depth: max_queue_depth,
      high_watermark: high_watermark,
      low_watermark: low_watermark,
      retry_after_ms: retry_after_ms
    }
  end

  def status(queue_depth, config, previous \\ nil)

  def status(
        queue_depth,
        %{
          max_queue_depth: max_queue_depth,
          high_watermark: high_watermark,
          low_watermark: low_watermark
        },
        previous
      ) do
    cond do
      queue_depth >= max_queue_depth -> "saturated"
      previous_backpressure?(previous) and queue_depth > low_watermark -> "pressured"
      queue_depth >= high_watermark -> "pressured"
      true -> "normal"
    end
  end

  defp previous_backpressure?(%{"backpressure" => true}), do: true
  defp previous_backpressure?(%{backpressure: true}), do: true
  defp previous_backpressure?(_), do: false

  def saturated?(snapshot), do: Map.get(snapshot, "status") == "saturated"
  def pressured?(snapshot), do: Map.get(snapshot, "backpressure") == true

  def retry_later_reason(snapshot, extra \\ %{}) do
    Map.merge(
      %{
        "reason" => "backpressure",
        "retry_after_ms" => Map.get(snapshot, "retry_after_ms", @default_retry_after_ms),
        "pressure" => snapshot
      },
      extra
    )
  end

  def process_queue_depth(pid, internal_depth \\ 0) when is_pid(pid) do
    mailbox_queue_depth(pid) + max(as_int(internal_depth, 0), 0)
  end

  defp mailbox_queue_depth(pid) when node(pid) == node() do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, value} when is_integer(value) -> value
      _ -> 0
    end
  end

  defp mailbox_queue_depth(pid) do
    case :rpc.call(node(pid), Process, :info, [pid, :message_queue_len], 5_000) do
      {:message_queue_len, value} when is_integer(value) -> value
      _ -> 0
    end
  end

  defp raw_config(%{config: config}) when is_map(config), do: raw_config(config)

  defp raw_config(config) when is_map(config) do
    case Map.get(config, "backpressure") || Map.get(config, :backpressure) do
      nested when is_map(nested) -> stringify_keys(nested)
      _ -> stringify_keys(config)
    end
  end

  defp raw_config(_), do: %{}

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp default_max_queue_depth do
    env_integer(
      "MN_DEFAULT_MAX_AGENT_QUEUE_DEPTH",
      Application.get_env(
        :mirror_neuron,
        :default_max_agent_queue_depth,
        @default_max_queue_depth
      )
    )
  end

  defp default_high_watermark(max_queue_depth) do
    env_integer(
      "MN_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK",
      Application.get_env(
        :mirror_neuron,
        :default_agent_queue_high_watermark,
        min(@default_high_watermark, max(max_queue_depth - 1, 1))
      )
    )
  end

  defp default_low_watermark(high_watermark) do
    env_integer(
      "MN_DEFAULT_AGENT_QUEUE_LOW_WATERMARK",
      Application.get_env(
        :mirror_neuron,
        :default_agent_queue_low_watermark,
        min(@default_low_watermark, high_watermark)
      )
    )
  end

  defp env_integer(env_name, default) do
    case System.get_env(env_name) do
      nil -> default
      "" -> default
      value -> as_int(value, default)
    end
  end

  defp as_int(value, _default) when is_integer(value), do: value

  defp as_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp as_int(_value, default), do: default
end
