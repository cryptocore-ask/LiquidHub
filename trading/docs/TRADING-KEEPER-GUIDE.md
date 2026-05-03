# Trading Keeper Guide

## Overview

Keepers are external participants who can execute public functions on the TradingVault to help maintain position health. When enabled, keepers earn USDC bounties from the Treasury.

## Bot-Authorized Closure Model

The TradingVault uses a **bot-authorized, public-executed** closure model for `executeStopLoss` and `executeTakeProfit`. Each closure must first be authorized by the protocol bot via `authorizeClosure(key, closureType)`, which emits a `ClosureAuthorized` event.

Once authorized, **any keeper has `keeperWindow` seconds** (default: 1 minute) to execute the closure and earn the bounty. After the window expires, the protocol bot closes the position itself as a fallback — keepers can no longer execute.

**Why this model?**
- The bot runs off-chain logic (technical analysis, AI signals, macro context) that cannot be verified on-chain
- The bot only authorizes closure when its full decision process agrees (e.g. price hit SL AND sentiment confirms reversal)
- Without this gating, community keepers could close positions the moment price touches SL, even if the bot's internal logic would have held them
- Community keepers still get a real opportunity to earn bounties — the bot deliberately waits 1 minute before falling back, giving keepers priority. The 1-minute window (vs 2 min for LP rebalances) limits price slippage on volatile trading positions.

### Flow diagram

```
  t=0                         t=120s                      t=120s+
  │                             │                             │
  │  Bot detects                │  Window expires             │
  │  valid exit                 │  (keeperWindow)             │
  │  conditions                 │                             │
  ▼                             ▼                             ▼
┌──────────────┐       ┌──────────────────┐       ┌──────────────────┐
│ Bot calls    │       │ Keepers can      │       │ Bot closes       │
│ authorize-   │──────►│ executeStopLoss/ │──────►│ the position     │
│ Closure()    │       │ executeTakeProfit│       │ itself (fallback)│
│              │       │ (first wins      │       │                  │
│              │       │  bounty)         │       │                  │
└──────────────┘       └──────────────────┘       └──────────────────┘
```

### Access rules

| Caller                        | Without authorization | With active authorization | After expiration |
|-------------------------------|:---------------------:|:-------------------------:|:----------------:|
| Community keeper (any EOA)    | ❌ Revert             | ✅ Can close              | ❌ Revert        |
| Protocol bot (owner/Safe)     | ✅ Can close          | ✅ Can close              | ✅ Can close     |

`liquidatePosition` is **NOT** subject to this gating — it remains fully permissionless as a last-resort safety net when a position is under the maintenance margin.

`closePosition` is `onlyBot` (called via `TradingBotModule` → Safe) and is used for manual admin closures regardless of price conditions.

### Authorization expiration

Authorizations are **consumed on success** (`delete closureAuthorizations[key]` after a successful close) and **expire automatically** after `keeperWindow` seconds. The bot can also explicitly revoke an authorization via `revokeClosureAuthorization(key)` if its internal signals reverse during the window.

---

## Public Functions

### executeStopLoss(bytes32 key)

Closes a position when the price reaches its stop-loss level **and the bot has authorized the closure**.

**Trigger conditions:**
- Position must be open (`isOpen == true`)
- Stop-loss price must be set (`stopLossPrice > 0`)
- Bot must have called `authorizeClosure(key, 1)` and the authorization must not have expired
- For longs: `currentPrice <= stopLossPrice`
- For shorts: `currentPrice >= stopLossPrice`

### executeTakeProfit(bytes32 key)

Closes a position when the price reaches its take-profit level **and the bot has authorized the closure**.

**Trigger conditions:**
- Position must be open (`isOpen == true`)
- Take-profit price must be set (`takeProfitPrice > 0`)
- Bot must have called `authorizeClosure(key, 2)` and the authorization must not have expired
- For longs: `currentPrice >= takeProfitPrice`
- For shorts: `currentPrice <= takeProfitPrice`

### isClosureAuthorized(bytes32 key, uint8 closureType) — view

Returns `true` if the bot has authorized closure of the given type (1=SL, 2=TP) for this position and the authorization hasn't expired. Use this to filter eligible positions before submitting a closure tx (avoids wasting gas on reverts).

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

    // IMPORTANT: before trying executeStopLoss/executeTakeProfit,
    // check that the bot has authorized closure (otherwise the tx will revert)
    const slAuthorized = await vault.isClosureAuthorized(key, 1); // 1 = STOP_LOSS
    const tpAuthorized = await vault.isClosureAuthorized(key, 2); // 2 = TAKE_PROFIT

    if (!slAuthorized && !tpAuthorized) continue; // skip, no authorization
    // ... check price conditions and execute
}
```

### Event-based approach (recommended)

Subscribe to the `ClosureAuthorized` event for a lower-latency path:

```javascript
vault.on('ClosureAuthorized', async (key, closureType, expiresAt) => {
    // A closure has been authorized — race other keepers to execute
    if (closureType === 1) {
        await vault.executeStopLoss(key, { value: EXECUTION_FEE });
    } else if (closureType === 2) {
        await vault.executeTakeProfit(key, { value: EXECUTION_FEE });
    }
});
```

First keeper to land a successful tx wins the bounty. The reference keeper implementation uses polling (simpler), but event-based listening gives you a latency advantage.

---

## Gas Costs

- Estimated gas per execution: ~500,000-1,500,000 gas
- On Arbitrum, gas is typically very cheap (< $0.01 per tx)
- Ensure your keeper wallet has sufficient ETH for gas

---

## Monitoring

The protocol also runs its own position watcher that checks every 30 seconds. Keepers provide redundancy and decentralization for critical position management.
