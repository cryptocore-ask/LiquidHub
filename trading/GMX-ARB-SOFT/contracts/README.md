# GMX v2 Trading Contracts

## Overview

Smart contracts for the Liquid Hub GMX v2 trading system on Arbitrum.

## Contracts

| Contract | Description |
|----------|-------------|
| `TradingVault.sol` | ERC-4626 USDC vault with GMX v2 perpetual trading, on-chain risk limits, and automatic commission to Treasury |
| `TradingBotModule.sol` | Gnosis Safe module restricting bot to whitelisted functions with daily transaction limits |
| `IGmxExchangeRouter.sol` | Interface for GMX v2 ExchangeRouter |
| `IGmxReader.sol` | Interface for GMX v2 Reader |
| `IGmxDataStore.sol` | Interface for GMX v2 DataStore |

## Architecture

```
User deposits USDC → TradingVault (ERC-4626)
Bot → TradingBotModule → Safe → TradingVault → GMX v2 ExchangeRouter
Profit → Commission (configurable %) → Treasury
Keeper → executeStopLoss / executeTakeProfit / liquidatePosition (public)
```

## On-Chain Risk Limits

The TradingVault enforces these limits in the contract, not just in the bot:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxPositionSizeBps` | 500 (5%) | Max % of vault per position |
| `maxTotalExposureBps` | 3000 (30%) | Max % of vault exposed total |
| `maxLeverage` | 5 | Maximum leverage |
| `maxConcurrentPositions` | 5 | Max simultaneous positions |

These are configurable by the Safe owner via setter functions.

## Build

```bash
forge install
forge build
```

## Deploy

```bash
# 1. Deploy TradingVault
forge script script/01_DeployTradingVault.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. Deploy TradingBotModule
forge script script/02_DeployTradingBotModule.s.sol --rpc-url $RPC_URL --broadcast --verify
```

## Dependencies

- OpenZeppelin Contracts v4.x
- Forge Standard Library
- Safe Contracts
