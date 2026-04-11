defmodule MirrorNeuron.Examples.SlackMonitor.SlackSensor do
  use MirrorNeuron.AgentTemplate
  require Logger

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime

  @impl true
  def init(node) do
    # Ensure HTTPC is ready for Slack API
    :inets.start()
    :ssl.start()

    {:ok,
     %{
       config: node.config || %{},
       channel: nil,
       last_ts: "0",
       mock_tick: 0,
       schedule_seq: 0,
       scheduled_token: nil
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    case type(message) do
      "start" ->
        payload = payload(message) || %{}
        channel = payload["channel"] || "clow"
        Logger.info("[SlackSensor] Starting monitor on channel: #{channel}")

        {:ok, schedule_poll(%{state | channel: channel}, context, 0), []}

      "poll" ->
        run_scheduled_poll(message, state, context)

      _ ->
        {:ok, state, []}
    end
  end

  @impl true
  def recover(%{channel: nil} = state, _context), do: {:ok, state, []}

  def recover(state, context) do
    {:ok, schedule_poll(state, context, poll_interval_ms(state.config)), []}
  end

  defp fetch_slack_messages(token, actual_channel_id, oldest_ts, mock_tick) do
    url =
      ~c"https://slack.com/api/conversations.history?channel=#{actual_channel_id}&oldest=#{oldest_ts}"

    headers = [{~c"Authorization", ~c"Bearer #{token}"}]

    case :httpc.request(:get, {url, headers}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        try do
          json = Jason.decode!(to_string(body))
          messages = json["messages"] || []

          new_ts =
            if length(messages) > 0 do
              hd(messages)["ts"]
            else
              oldest_ts
            end

          {new_ts, messages, mock_tick}
        rescue
          _e -> {oldest_ts, [], mock_tick}
        end

      _ ->
        {oldest_ts, [], mock_tick}
    end
  end

  defp resolve_channel_id(token, channel_name) do
    url = ~c"https://slack.com/api/conversations.list"
    headers = [{~c"Authorization", ~c"Bearer #{token}"}]

    case :httpc.request(:get, {url, headers}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        try do
          json = Jason.decode!(to_string(body))
          channels = json["channels"] || []
          channel = Enum.find(channels, fn c -> c["name"] == channel_name end)
          if channel, do: channel["id"], else: channel_name
        rescue
          _e -> channel_name
        end

      _ ->
        channel_name
    end
  end

  # Generates fake slack messages if no SLACK_TOKEN is provided
  defp mock_fetch_slack_messages(_oldest_ts, mock_tick) do
    new_tick = mock_tick + 1
    new_ts = to_string(:os.system_time(:millisecond))

    # Every 3 ticks, we simulate someone saying a money amount
    messages =
      if rem(new_tick, 3) == 0 do
        [%{"user" => "U123", "text" => "Hey, the new server costs $45 a month", "ts" => new_ts}]
      else
        [%{"user" => "U456", "text" => "Just checking in, tick #{new_tick}", "ts" => new_ts}]
      end

    {new_ts, messages, new_tick}
  end

  @impl true
  def inspect_state(state) do
    %{channel: state.channel, last_ts: state.last_ts, mock_tick: state.mock_tick}
  end

  defp run_scheduled_poll(message, %{scheduled_token: token} = state, context) do
    if Map.get(payload(message) || %{}, "token") == token do
      token = System.get_env("SLACK_BOT_TOKEN")
      channel_id = state.channel || System.get_env("SLACK_DEFAULT_CHANNEL") || "#claw"

      actual_channel_id =
        if String.starts_with?(channel_id, "#") do
          resolve_channel_id(token, String.trim_leading(channel_id, "#"))
        else
          channel_id
        end

      {new_ts, new_messages, mock_tick} =
        if token do
          fetch_slack_messages(token, actual_channel_id, state.last_ts, state.mock_tick)
        else
          mock_fetch_slack_messages(state.last_ts, state.mock_tick)
        end

      actions =
        Enum.map(new_messages, fn msg ->
          {:emit_to, "money_detector", "slack_message", msg}
        end)

      next_state =
        state
        |> Map.put(:last_ts, new_ts)
        |> Map.put(:mock_tick, mock_tick)
        |> Map.put(:channel, actual_channel_id)
        |> Map.put(:scheduled_token, nil)
        |> schedule_poll(context, poll_interval_ms(state.config))

      {:ok, next_state, actions}
    else
      {:ok, state, []}
    end
  end

  defp run_scheduled_poll(_message, state, _context), do: {:ok, state, []}

  defp schedule_poll(state, context, delay_ms) do
    token = state.schedule_seq + 1

    spawn(fn ->
      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end

      Runtime.deliver(
        context.job_id,
        context.node.node_id,
        Message.new(
          context.job_id,
          context.node.node_id,
          context.node.node_id,
          "poll",
          %{"token" => token},
          class: "control"
        )
      )
    end)

    %{state | schedule_seq: token, scheduled_token: token}
  end

  defp poll_interval_ms(config), do: Map.get(config, "poll_interval_ms", 3000)
end
