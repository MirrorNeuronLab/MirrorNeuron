# Synthetic Market Simulation (Agent-Based) — SPEC.md

## 1. Objective
Build a multi-agent simulation of financial markets grounded in historical data to:
- Reproduce known events (e.g., liquidity shocks, flash crashes)
- Stress test strategies and market structure
- Analyze causal interactions between heterogeneous agents

## 2. Core Principles
- Data-anchored: historical data provides baseline state and calibration
- Agent heterogeneity: different objectives, constraints, and policies
- Event-driven: all interactions via time-ordered events
- Reproducible: deterministic seeds + versioned policies

## 3. System Architecture
- Runtime: distributed actor model (e.g., BEAM-style)
- World State:
  - Order books per asset
  - Agent states (portfolio, inventory, risk)
  - Global signals (price, volatility, liquidity)
- Event Bus:
  - Order submission
  - Trade execution
  - Market data update
  - External events (news, macro shock)

## 4. Agent Types
- Institutional (portfolio optimization, execution strategies)
- Market Makers (spread control, inventory risk)
- Retail (sentiment-driven, momentum)
- Arbitrage (cross-asset inefficiencies)
- Regulator/Exchange (rules, halts)

## 5. Data Inputs
- Historical price + volume (tick or bar)
- Order book snapshots (if available)
- Macro events timeline (rates, news)
- Calibration targets (volatility, spreads, correlations)

## 6. Simulation Flow
1. Initialize market state from historical snapshot
2. Instantiate agents with parameters
3. Replay historical timeline (baseline signals)
4. Agents observe + act (submit orders, adjust positions)
5. Matching engine executes trades
6. Update global state
7. Repeat until end of scenario

## 7. Communication Model
- Explicit:
  - Order book (shared environment)
  - Trade events
- Implicit:
  - Price movement
  - Volatility signals
  - Liquidity depth

## 8. Metrics Collected
- Price path, volatility, liquidity depth
- Agent-level PnL, inventory, actions
- System metrics:
  - Drawdown
  - Time to recovery
  - Liquidity collapse events

## 9. Causal Analysis Layer
- Build interaction graph from events
- Identify:
  - Trigger agents
  - Amplifiers
  - Feedback loops

## 10. Output
- Structured JSON logs
- Aggregated metrics
- Report generator (see Ideal Output Report)

## 11. Reproducibility
- Seeded randomness
- Versioned agent policies
- Logged configuration

## 12. Extensions
- RL training environment
- Scenario generation (counterfactuals)
- Policy testing (regulatory changes)
