# Trading Keeper Guide

## Overview

Keepers are external participants who can execute public functions on the TradingVault to help maintain position health. When enabled, keepers earn USDC bounties from the Treasury.

---

## Public Functions

### executeStopLoss(bytes32 key)

Closes a position when the price reaches its stop-loss level.

**Trigger conditions:**
- Position must be open (`isOpen == true`)
- Stop-loss price must be set (`stopLossPrice > 0`)
- For longs: `currentPrice <= stopLossPrice`
- For shorts: `currentPrice >= stopLossPrice`

### executeTakeProfit(bytes32 key)

Closes a position when the price reaches its take-profit level.

**Trigger conditions:**
- Position must be open (`isOpen == true`)
- Take-profit price must be set (`takeProfitPrice > 0`)
- For longs: `currentPrice >= takeProfitPrice`
- For shorts: `currentPrice <= takeProfitPrice`

### liquidatePosition(bytes32 key)

Liquidates a position when collateral falls below the maintenance margin.

**Trigger conditions:**
- Position must be open (`isOpen == true`)
- `collateral * 1e24 <= sizeInUsd / 100` (collateral < 1% of position size)

---

## Bounty

- **Default**: Disabled (`keeperBountyEnabled = false`)
- **Amount**: Configurable via `KEEPER_BOUNTY_AMOUNT` (default: 500000 = 0.50 USDC)
- **Source**: Paid by `Treasury.payKeeperBounty(keeper)`
- **Failure handling**: Bounty payment failure never reverts the position close

The Safe owner enables bounties in two steps:
1. `TradingVault.setKeeperBountyEnabled(true)`
2. `Treasury.setKeeperBounty(true, amount)`

---

## Setup

```bash
cd keeper-bot
npm install
cp ../.env.example .env
# Edit .env: set RPC_URL, TRADING_VAULT_ADDRESS, KEEPER_PRIVATE_KEY
node src/keeper.js
```

---

## Reading Position Data

To find executable positions, read from the TradingVault:

```javascript
const count = await vault.getActivePositionCount();
for (let i = 0; i < count; i++) {
    const key = await vault.activePositionKeys(i);
    const pos = await vault.positions(key);
    // Check SL/TP/liquidation conditions
}
```

---

## Gas Costs

- Estimated gas per execution: ~500,000-1,500,000 gas
- On Arbitrum, gas is typically very cheap (< $0.01 per tx)
- Ensure your keeper wallet has sufficient ETH for gas

---

## Monitoring

The protocol also runs its own position watcher that checks every 30 seconds. Keepers provide redundancy and decentralization for critical position management.
