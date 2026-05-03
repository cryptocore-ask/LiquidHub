# Liquid Hub - Delta Neutral Keeper Bot

Keeper bot for the Liquid Hub Delta Neutral (DN) pool **UNI-ARB-WETH-USDC-DN**. This bot extends the standard keeper bot with AAVE V3 hedge monitoring and recalibration.

## Overview

The DN keeper bot performs the same rebalancing cycle as the standard pool. The keeper submits a single atomic transaction to `rebalance()` on the RangeManager, which performs lock → burn → swap(s) → mint → unlock → bounty internally. Swaps are automatically split into chunks ≤ `initMultiSwapTvl` (read on-chain).

At each polling cycle the bot also displays the current AAVE V3 hedge health factor alongside the standard position data.

The `rebalance()` function is **fully permissionless** — any address can call it when `getBotInstructions()` indicates a rebalance is needed. No whitelisting or keeper role required.

## Setup

```bash
cp ../../.env.example .env
# Fill in your values
npm install
```

## Environment Variables

All standard keeper variables apply (see the standard pool README). The DN bot adds:

| Variable | Description | Default |
|---|---|---|
| `AAVE_HEDGE_MANAGER_ADDRESS` | AaveHedgeManager contract address | -- |
| `AAVE_HEALTH_WARN` | Health factor warning threshold | `1.25` |
| `AAVE_HEALTH_DELEVERAGE` | Health factor deleverage threshold | `1.15` |
| `AAVE_HEALTH_EMERGENCY` | Health factor emergency threshold | `1.05` |

## Usage

```bash
# Active mode -- monitors and executes rebalances
npm start

# Check-only mode -- reads state once and exits
npm run check
```

## License

BUSL-1.1
