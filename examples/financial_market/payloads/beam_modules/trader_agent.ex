defmodule MirrorNeuron.Examples.FinancialMarket.TraderAgent do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    config = node.config || %{}

    {:ok,
     %{
       config: config,
       agent_id: node.node_id,
       strategy: config["strategy"] || "noise",
       portfolio: %{"cash" => 10000.0, "stock" => 100},
       price_history: [],
       total_trades: 0,
       duration_seconds: Map.get(config, "duration_seconds", 30)
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    case type(message) do
      "market_data" ->
        payload = payload(message)
        last_price = payload["last_price"]

        history = [last_price | Enum.take(state.price_history, 9)]
        state = %{state | price_history: history}

        action = decide(state.strategy, history, state.portfolio)

        actions =
          case action do
            {"buy", p, q} ->
              [
                {:emit_to, "exchange", "place_order",
                 %{"side" => "buy", "price" => p, "quantity" => q, "agent_id" => state.agent_id},
                 []}
              ]

            {"sell", p, q} ->
              [
                {:emit_to, "exchange", "place_order",
                 %{"side" => "sell", "price" => p, "quantity" => q, "agent_id" => state.agent_id},
                 []}
              ]

            _ ->
              []
          end

        tick = payload["tick"]

        actions =
          if tick >= state.duration_seconds do
            summary = %{
              "agent_id" => state.agent_id,
              "role" => state.strategy,
              "final_portfolio" => state.portfolio,
              "total_trades" => state.total_trades
            }

            actions ++ [{:emit_to, "collector", "trader_summary", summary, [class: "event"]}]
          else
            actions
          end

        {:ok, state, actions}

      "trade_executed" ->
        trade = payload(message)
        cash = state.portfolio["cash"]
        stock = state.portfolio["stock"]

        new_portfolio =
          if trade["buyer"] == state.agent_id do
            %{
              "cash" => cash - trade["price"] * trade["quantity"],
              "stock" => stock + trade["quantity"]
            }
          else
            %{
              "cash" => cash + trade["price"] * trade["quantity"],
              "stock" => stock - trade["quantity"]
            }
          end

        {:ok, %{state | portfolio: new_portfolio, total_trades: state.total_trades + 1}, []}

      _ ->
        {:ok, state, []}
    end
  end

  def decide("momentum", [p1, p2 | _], _portfolio) when p1 > p2 do
    {"buy", p1 * 1.01, 10}
  end

  def decide("momentum", [p1, p2 | _], _portfolio) when p1 < p2 do
    {"sell", p1 * 0.99, 10}
  end

  def decide("mean_reversion", history, _portfolio) when length(history) >= 5 do
    avg = Enum.sum(history) / length(history)
    p1 = hd(history)

    if p1 < avg * 0.98 do
      {"buy", p1 * 1.01, 20}
    else
      if p1 > avg * 1.02 do
        {"sell", p1 * 0.99, 20}
      else
        nil
      end
    end
  end

  def decide("noise", [p1 | _], _portfolio) do
    if :rand.uniform() < 0.2 do
      if :rand.uniform() < 0.5 do
        {"buy", p1 * (1.0 + (:rand.uniform() - 0.5) * 0.02), 5}
      else
        {"sell", p1 * (1.0 + (:rand.uniform() - 0.5) * 0.02), 5}
      end
    else
      nil
    end
  end

  def decide("market_maker", [p1 | _], _portfolio) do
    # Simply place a random side order very close to last price
    if :rand.uniform() < 0.5 do
      {"buy", p1 * 0.995, 100}
    else
      {"sell", p1 * 1.005, 100}
    end
  end

  def decide(_, _, _), do: nil

  @impl true
  def inspect_state(state) do
    %{agent_id: state.agent_id, portfolio: state.portfolio}
  end
end
