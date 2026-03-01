# Protocol Architecture

## Overview

Liquid Hub manages Uniswap V3 concentrated liquidity positions for multiple users via a vault system. Users deposit tokens, receive shares proportional to their contribution, and benefit from actively managed LP positions without needing to manage ranges themselves.

## Core Flow

1. **Deposit** — Users deposit WETH + USDC into `MultiUserVault` and receive shares representing their proportional ownership.
2. **Delegation** — The vault delegates LP management to `RangeManager`, which handles all Uniswap V3 position logic.
3. **Position Creation** — `RangeManager` creates Uniswap V3 concentrated liquidity positions with dynamic ranges, configured on-chain by a Gnosis Safe multisig.
4. **Rebalance** — When price moves out of range, a keeper triggers a rebalance: burn the old position, swap tokens to rebalance the ratio, then mint a new position at the optimal range.
5. **Fee Collection** — Protocol fees (LP commissions) are collected during each rebalance and sent to the Treasury contract.
6. **Withdrawal** — Users withdraw by burning their shares. The vault burns the proportional LP position and returns the underlying tokens to the user.

---

## Pool Types

### Standard Pool

- Directional exposure to both tokens (WETH and USDC).
- LP earns swap fees from the Uniswap V3 pool.
- Simple deposit/withdraw lifecycle with no hedging.

### Delta Neutral (DN) Pool

- Same LP mechanism as a standard pool — positions are minted in Uniswap V3 and earn swap fees.
- Additionally uses an **AAVE V3 hedge** to neutralize directional price exposure:
  - A reserve ratio (62.5%) of USDC is supplied as AAVE collateral.
  - WETH is borrowed against the collateral (LTV target 60%).
  - The borrowed WETH offsets the LP's long WETH exposure.
- **Net effect**: LP fees are earned without directional price exposure.
- **Withdrawals are atomic**: burn LP, flash loan settlement (if needed), return tokens to user in a single transaction.
- **Health Factor** is monitored continuously:
  - Warn threshold: 1.25
  - Deleverage threshold: 1.15
  - Emergency threshold: 1.05

---

## Multi-Swap System

Large swaps are split into smaller chunks to reduce price impact on the pool:

- Default chunk size: `INIT_MULTI_SWAP_TVL` (~$10k per swap).
- Each chunk is a separate on-chain transaction via Uniswap V3 `SwapRouter`.
- A 2-second delay between swaps allows arbitrageurs to reset the pool price.
- This mechanism ensures minimal slippage even for large TVL pools.

---

## Rebalance Flow (Detailed)

1. **`startRebalance()`** — Lock the vault (no deposits or withdrawals allowed during rebalance).
2. **`burnPosition(tokenId)`** — Remove the current LP position from Uniswap V3, collect accrued fees.
3. **[DN only] Recalibrate AAVE hedge** — Adjust the borrow/supply on AAVE to match the new position parameters.
4. **N x `executeSwap()`** — Execute one or more swaps to rebalance the token ratio for the new range. Uses the multi-swap system for large amounts.
5. **`mintInitialPosition()`** — Create a new LP position at the optimal range configured by the Safe multisig.
6. **`endRebalance()`** — Unlock the vault, pay keeper bounty (if enabled).

---

## Commission System

- **LP commissions** are collected on each rebalance (`TAUX_PRELEV_PRCT`, default 10% of earned fees).
- Commissions are sent to the Treasury contract in WETH + USDC.
- Treasury can convert any ERC-20 token to USDC via `swapToUSDC(tokenIn, fee, amountIn, minAmountOut)`.
- **Frontend swap commission**: a partner fee (`PARTNER_FEE_BPS=3`, i.e. 0.03%) is applied on frontend swaps and sent directly to the Treasury. The Treasury accepts any token received from these swaps.
