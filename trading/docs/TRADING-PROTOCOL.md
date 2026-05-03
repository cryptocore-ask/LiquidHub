# Trading Protocol

## Overview

The Liquid Hub Trading system enables automated perpetual trading on GMX v2, managed through a Gnosis Safe multisig with on-chain risk controls. Users deposit USDC into the TradingVault, and the bot opens/closes positions based on a combination of technical analysis and AI signals.

---

## Flow

```
1. User deposits USDC → TradingVault (ERC-4626 shares)
2. Bot analyzes markets (technical indicators + Grok AI)
3. Signal aggregation: conviction = tech × 0.45 + sentiment × 0.30 + macro × 0.25
4. If conviction >= threshold → open position via GMX v2
5. Bot monitors positions (trailing stop, risk evaluation)
6. On close: if profit → commission (% of net profit) → Treasury
7. User withdraws: burn shares → USDC
```

---

## Commission System

- Commission is calculated on **net positive PnL** only (no commission on losses).
- Rate is configurable via `setCommissionRate(uint256 _rate)` (in basis points, e.g., 1000 = 10%).
- USDC is sent **directly and automatically** to the Treasury contract on each profitable position close.
- Same pattern as LP pool commissions — Treasury accumulates fees from all sources.

---

## Risk Management (On-Chain)

These limits are **enforced in the TradingVault contract**, not just in the bot:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxPositionSizeBps` | 500 (5%) | Max % of vault per single position |
| `maxTotalExposureBps` | 3000 (30%) | Max % of vault engaged across all positions |
| `maxLeverage` | 5x | Maximum leverage per position |
| `maxConcurrentPositions` | 5 | Maximum simultaneous open positions |

Even if the bot is compromised, it cannot exceed these limits. Only the Safe multisig owner can modify them.

---

## Risk Management (Off-Chain)

The bot also applies additional off-chain checks:

| Parameter | Description |
|-----------|-------------|
| `MAX_DAILY_LOSS_PERCENT` | Circuit breaker — stops trading if daily loss exceeds threshold |
| `DEFAULT_LEVERAGE` | Default leverage used by the bot (can be lower than on-chain max) |
| `AI_MIN_CONVICTION_THRESHOLD` | Minimum signal conviction to open a position |

---

## Keeper Functions

Public functions allow community keepers to execute critical position management. SL/TP closures are **bot-gated** (the protocol bot authorizes each closure for a 1-minute window), while liquidation is fully permissionless.

| Function | Trigger | Authorization | Description |
|----------|---------|---------------|-------------|
| `executeStopLoss(key)` | Price hits SL **and** bot authorized | Bot calls `authorizeClosure(key, 1)` — 2 min window | Closes position at SL |
| `executeTakeProfit(key)` | Price hits TP **and** bot authorized | Bot calls `authorizeClosure(key, 2)` — 2 min window | Closes position at TP |
| `liquidatePosition(key)` | Collateral below maintenance margin | Permissionless | Liquidates position |
| `settleAll()` | Pending settlements | Permissionless | Settles pending commissions |

**Why SL/TP closures are bot-gated**: the protocol bot runs off-chain logic (technical analysis + AI sentiment + macro) that cannot be verified on-chain. When the bot's full decision process agrees with the closure, it authorizes it — giving community keepers a 1-minute window to execute and earn the bounty. After the window, the bot closes itself as a fallback.

See the [Keeper Guide](./TRADING-KEEPER-GUIDE.md) for the full closure authorization model and keeper setup.

Keeper bounties (paid from Treasury) are **disabled by default** and can be enabled by the Safe owner.

---

## Position Watcher

A continuous monitoring process (separate from the trading bot) checks all positions every 30 seconds:

- **Warning**: Alert when distance to liquidation < `LIQUIDATION_WARN_PERCENT` (default: 15%)
- **Critical**: Emergency close when distance < `LIQUIDATION_CRITICAL_PERCENT` (default: 5%)
- **Backup SL/TP**: Executes stop-loss/take-profit if the main bot hasn't acted

---

## GMX v2 Integration

- Trading via GMX v2 ExchangeRouter on Arbitrum
- Supports ~90 perpetual markets (ETH, BTC, ARB, SOL, LINK, etc.)
- GMX contract addresses are stored as **mutable storage** (not immutable) because GMX v2 updates its contracts periodically
- Health check verifies vault GMX addresses match expected values on startup

---

## Signal Sources

| Source | Weight | Tool |
|--------|--------|------|
| Technical Analysis | 45% | RSI, MACD, Bollinger Bands, EMA (multi-timeframe) |
| Grok x_search (sentiment) | 30% | Twitter/X real-time sentiment analysis |
| Grok web_search (macro) | 25% | Macroeconomic events, regulation, DeFi news |

Price data for technical analysis comes from **Binance API** (primary) and **CoinGecko** (fallback). GMX does not provide candle history.
