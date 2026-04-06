defmodule MirrorNeuron.Examples.SlackMonitor.MoneyDetector do
  use MirrorNeuron.AgentTemplate
  require Logger

  @impl true
  def init(node) do
    # Ensure HTTPC is ready for Slack API
    :inets.start()
    :ssl.start()

    {:ok,
     %{
       config: node.config || %{},
       total_violations: 0
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    case type(message) do
      "slack_message" ->
        payload = payload(message)
        text = payload["text"] || ""
        user = payload["user"] || "Unknown"

        # Regex to detect dollar sign followed by numbers
        if String.match?(text, ~r/\$\d+/) do
          Logger.warning("[MoneyDetector] Detected money talk from #{user}: '#{text}'")

          # Send reply warning to slack
          token = System.get_env("SLACK_BOT_TOKEN")

          channel = System.get_env("SLACK_DEFAULT_CHANNEL") || "#claw"

          if token do
            send_slack_message(token, channel, "PLEASE NO TALK ABOUT MONEY")
          else
            Logger.error("[MoneyDetector] Missing SLACK_BOT_TOKEN. Cannot send warning.")
          end

          {:ok, %{state | total_violations: state.total_violations + 1}, []}
        else
          # No money detected, ignore
          {:ok, state, []}
        end

      _ ->
        {:ok, state, []}
    end
  end

  defp send_slack_message(token, channel_id, text) do
    url = ~c"https://slack.com/api/chat.postMessage"

    headers = [
      {~c"Authorization", to_charlist("Bearer #{token}")},
      {~c"Content-Type", ~c"application/json"}
    ]

    body =
      Jason.encode!(%{
        "channel" => channel_id,
        "text" => text
      })

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        Logger.info("[MoneyDetector] Successfully sent warning to Slack.")
        {:ok, response_body}

      error ->
        Logger.error("[MoneyDetector] Failed to send message to Slack: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def inspect_state(state) do
    %{total_violations: state.total_violations}
  end
end
