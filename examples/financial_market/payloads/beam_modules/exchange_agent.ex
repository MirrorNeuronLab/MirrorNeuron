defmodule MirrorNeuron.Examples.FinancialMarket.ExchangeAgent do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    config = node.config || %{}

    {:ok,
     %{
       config: config,
       tick: 0,
       bids: [],
       asks: [],
       last_price: Map.get(config, "initial_price", 100.0) |> to_float(),
       price_history: [],
       trades: [],
       duration_seconds: Map.get(config, "duration_seconds", 30)
     }}
  end

  defp to_float(v) when is_number(v), do: v * 1.0
  defp to_float(v) when is_binary(v), do: String.to_float(v)
  defp to_float(_), do: 0.0

  @impl true
  def handle_message(message, state, _context) do
    case type(message) do
      "simulation_start" ->
        {:ok, state,
         [
           {:emit_to, "exchange", "market_tick", %{"tick" => 1}, [class: "command"]}
         ]}

      "place_order" ->
        payload = payload(message)
        side = payload["side"]
        price = payload["price"] |> to_float()
        quantity = payload["quantity"]
        agent_id = payload["agent_id"]

        state =
          if side == "buy" do
            %{
              state
              | bids:
                  [{price, quantity, agent_id} | state.bids]
                  |> Enum.sort_by(fn {p, _, _} -> -p end)
            }
          else
            %{
              state
              | asks:
                  [{price, quantity, agent_id} | state.asks]
                  |> Enum.sort_by(fn {p, _, _} -> p end)
            }
          end

        {:ok, state, []}

      "market_tick" ->
        tick = payload(message)["tick"]

        delay = Map.get(state.config, "tick_delay_ms", 0)

        if delay > 0 do
          Process.sleep(delay)
        end

        {new_bids, new_asks, new_trades, new_price} =
          match_orders(state.bids, state.asks, state.last_price, [])

        state = %{
          state
          | bids: new_bids,
            asks: new_asks,
            last_price: new_price,
            price_history: [new_price | state.price_history],
            trades: new_trades ++ state.trades
        }

        market_data = %{
          "tick" => tick,
          "last_price" => new_price,
          "bid_depth" => Enum.sum(Enum.map(new_bids, fn {_, q, _} -> q end)),
          "ask_depth" => Enum.sum(Enum.map(new_asks, fn {_, q, _} -> q end))
        }

        trade_actions =
          Enum.flat_map(new_trades, fn t ->
            [
              {:emit_to, t["buyer"], "trade_executed", t, []},
              {:emit_to, t["seller"], "trade_executed", t, []}
            ]
          end)

        actions =
          trade_actions ++
            [
              {:emit, "market_data", market_data, [class: "event"]}
            ]

        if tick < state.duration_seconds do
          actions =
            actions ++
              [
                {:emit_to, "exchange", "market_tick", %{"tick" => tick + 1}, [class: "command"]}
              ]

          {:ok, %{state | tick: tick}, actions}
        else
          summary = %{
            "agent_id" => "exchange",
            "role" => "exchange",
            "final_price" => new_price,
            "price_history" => Enum.reverse(state.price_history),
            "total_trades" => length(state.trades)
          }

          actions =
            actions ++
              [
                {:emit_to, "collector", "exchange_summary", summary, [class: "event"]}
              ]

          {:ok, %{state | tick: tick}, actions}
        end

      _ ->
        {:ok, state, []}
    end
  end

  def match_orders(
        [{bid_p, bid_q, bid_a} | rest_bids],
        [{ask_p, ask_q, ask_a} | rest_asks],
        _last_price,
        trades
      )
      when bid_p >= ask_p do
    trade_q = min(bid_q, ask_q)
    trade_p = (bid_p + ask_p) / 2.0
    trade = %{"price" => trade_p, "quantity" => trade_q, "buyer" => bid_a, "seller" => ask_a}

    new_bids =
      if bid_q > trade_q, do: [{bid_p, bid_q - trade_q, bid_a} | rest_bids], else: rest_bids

    new_asks =
      if ask_q > trade_q, do: [{ask_p, ask_q - trade_q, ask_a} | rest_asks], else: rest_asks

    match_orders(new_bids, new_asks, trade_p, [trade | trades])
  end

  def match_orders(bids, asks, last_price, trades) do
    {bids, asks, Enum.reverse(trades), last_price}
  end

  @impl true
  def inspect_state(state) do
    %{
      tick: state.tick,
      last_price: state.last_price,
      bids: length(state.bids),
      asks: length(state.asks)
    }
  end
end
