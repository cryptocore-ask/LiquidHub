# Trading Security

## Overview

The trading system uses a multi-layered security model to protect user funds deposited in the TradingVault.

---

## Gnosis Safe Multisig (2/3)

The TradingVault owner is a **2-of-3 Gnosis Safe multisig**. All administrative actions require multiple signers:

- Changing commission rates
- Modifying GMX contract addresses
- Adjusting on-chain risk limits
- Enabling/disabling keeper bounties
- Transferring ownership

---

## TradingBotModule — Function Whitelist

The bot operates through a **Safe Module** that restricts which functions can be called:

| Function | Access | Description |
|----------|--------|-------------|
| `openPosition(...)` | Bot only (via module) | Open a new position on GMX |
| `closePosition(bytes32)` | Bot only (via module) | Close an existing position (admin/manual) |
| `updateStopLoss(bytes32,uint256)` | Bot only (via module) | Update stop-loss price |
| `updateTakeProfit(bytes32,uint256)` | Bot only (via module) | Update take-profit price |
| `authorizeClosure(bytes32,uint8)` | Bot only (via module) | Authorize keepers to execute SL/TP for `keeperWindow` seconds |
| `revokeClosureAuthorization(bytes32)` | Bot only (via module) | Revoke a previously issued closure authorization |
| `executeStopLoss(bytes32)` | **Public** (keeper, gated) | Execute SL — requires active authorization OR owner |
| `executeTakeProfit(bytes32)` | **Public** (keeper, gated) | Execute TP — requires active authorization OR owner |
| `liquidatePosition(bytes32)` | **Public** (keeper, permissionless) | Liquidate when under maintenance margin |
| `deposit(uint256)` | **Public** (user) | Deposit USDC |
| `withdraw(uint256)` | **Public** (user) | Withdraw USDC |
| `setKeeperWindow(uint256)` | **Owner only** (Safe) | Configure keeper priority window (30-600s) |
| `set*` functions | **Owner only** (Safe) | Administrative configuration |

The module also enforces:
- **Daily transaction limit**: Maximum transactions per day (configurable, default: 50)
- **Pause capability**: Module can be paused by the Safe owner
- **Function allowlist**: Only whitelisted function selectors can be called

---

## On-Chain Risk Limits

Risk parameters are enforced **in the smart contract** (not just in the bot), ensuring decentralized protection:

```solidity
require(activePositionKeys.length < maxConcurrentPositions, "Max positions reached");
require(collateralAmount * 10000 / totalAssets() <= maxPositionSizeBps, "Position too large");
require(totalExposure + sizeInUsd <= totalAssets() * maxTotalExposureBps / 10000, "Max exposure");
require(leverage <= maxLeverage, "Max leverage");
```

Even a compromised bot cannot exceed these limits.

---

## User Fund Safety

- Users deposit/withdraw USDC freely through standard ERC-4626 vault functions
- The bot cannot withdraw user funds — it can only open/close positions on GMX
- Commissions are taken only from **net profits**, never from principal
- The `rescueToken` and `rescueETH` functions (owner only) exist for emergency recovery of stuck tokens

---

## GMX Address Mutability

GMX v2 contracts may be updated by the GMX team. To handle this:

- GMX addresses are stored as **mutable storage variables** (not immutable)
- Only the Safe owner can update them via `setGmxExchangeRouter()`, `setGmxReader()`, `setGmxDataStore()`
- The bot performs a **health check on startup** comparing on-chain addresses with expected values
- Address mismatch triggers an immediate bot shutdown + Telegram alert

---

## Commission Flow

```
Position closed with profit
    └→ commission = netProfit × commissionRateBps / 10000
        └→ USDC.safeTransfer(treasuryAddress, commission)
            └→ Treasury accumulates fees
```

Commission is sent directly to the Treasury. No intermediate steps, no manual intervention.

---

## Keeper Bounty Security

- Keeper bounties use `Treasury.payKeeperBounty()` in a **try/catch** block
- Bounty failure **never reverts** the position close — user safety takes priority
- The TradingVault must be explicitly authorized on the Treasury via `authorizeRangeManager()`
- Bounties are **disabled by default** (`keeperBountyEnabled = false`)
