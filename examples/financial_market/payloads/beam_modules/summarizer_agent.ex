defmodule MirrorNeuron.Examples.FinancialMarket.SummarizerAgent do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(_node) do
    {:ok, %{}}
  end

  @impl true
  def handle_message(message, state, _context) do
    case type(message) do
      "market_collection" ->
        payload = payload(message)

        # payload is %{"messages" => [...], "count" => 501, "last_message" => ...}
        messages = Map.get(payload, "messages", [])

        exchange_summary = Enum.find(messages, fn s -> s["role"] == "exchange" end) || %{}
        trader_summaries = Enum.reject(messages, fn s -> s["role"] == "exchange" end)

        final_summary = %{
          "final_price" => Map.get(exchange_summary, "final_price", 100.0),
          "price_history" => Map.get(exchange_summary, "price_history", []),
          "total_trades" => Map.get(exchange_summary, "total_trades", 0),
          "agent_summaries" => trader_summaries
        }

        {:ok, state,
         [
           {:complete_job, %{"market_summary" => final_summary}}
         ]}

      _ ->
        {:ok, state, []}
    end
  end

  @impl true
  def inspect_state(state), do: state
end
