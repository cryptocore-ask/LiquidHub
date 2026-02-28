# Liquid Hub - Delta Neutral Keeper Bot

Keeper bot for the Liquid Hub Delta Neutral (DN) pool **UNI-ARB-WETH-USDC-DN**. This bot extends the standard keeper bot with AAVE V3 hedge monitoring and recalibration.

## Overview

The DN keeper bot performs the same rebalancing cycle as the standard pool (burn out-of-range position, swap tokens, mint new position) but adds an AAVE V3 hedge health check between the burn and swap/mint steps:

1. **Lock vault** -- `startRebalance()`
2. **Burn position** -- Remove liquidity from Uniswap V3
3. **Check AAVE hedge** -- Read health factor, log status (EMERGENCY / DELEVERAGE / WARNING / OK)
4. **Calculate optimal swap** -- Determine token ratio for new range
5. **Execute swap(s)** -- Multi-swap chunking for large amounts
6. **Mint new position** -- Deploy liquidity in new range
7. **Unlock vault** -- `endRebalance()`

At each polling cycle the bot also displays the current AAVE health factor alongside the standard position data.

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
