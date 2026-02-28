# Treasury

## Overview

The on-chain Treasury contract collects protocol fees and manages fund distribution. It serves as the central revenue hub for the Liquid Hub protocol, accumulating fees from LP commissions and frontend swap commissions.

---

## Fee Sources

| Source | Tokens | Mechanism |
|--------|--------|-----------|
| LP commissions | WETH + USDC | Collected during each rebalance, sent from vault to Treasury |
| Frontend swap commissions | USDC | Via DEX aggregator partner fee (`PARTNER_FEE_BPS=3`, 0.03%) |

---

## Admin Withdrawal

- **Monthly cap**: `USDC_MONTHLY_CAP` (default: 5,000 USDC).
- **Only the owner** (Gnosis Safe multisig) can call `adminWithdraw()`.
- The cap resets every 30 days automatically.
- **Permanent disable**: `disableAdminWithdraw()` can be called by the owner to permanently and **irreversibly** disable all admin withdrawals. This is a safety mechanism to guarantee users that protocol revenue cannot be extracted by admins.

---

## swapToUSDC()

- **Public function** — anyone can call it.
- Converts the Treasury's WETH balance to USDC via Uniswap V3.
- Tokens remain in the Treasury after the swap.
- Useful for consolidating revenue into a single token before distribution.

---

## Keeper Bounty

- Configurable bounty amount in USDC (`KEEPER_BOUNTY_AMOUNT`).
- Enabled or disabled via `setKeeperBounty()` (owner only).
- Paid automatically after a successful rebalance by an authorized `RangeManager`.
- `payKeeperBounty()` is called by the `RangeManager` inside a try/catch — if the bounty is disabled or Treasury has insufficient funds, it will **not** revert the rebalance.

---

## Authorization

- `RangeManager` contracts must be explicitly authorized via `authorizeRangeManager()` before they can trigger bounty payments.
- Only the owner (Safe multisig) can authorize or revoke `RangeManager` addresses.

---

## Phase 2 (Future)

The Treasury contract includes built-in support for future staking and cross-chain distribution:

- **LayerZero bridge**: `bridgeToStakers()` sends USDC to a `StakingRewards` contract on a destination chain (e.g., Base).
- **Local staking**: `distributeToStakers()` for same-chain distribution to stakers.
- **Configuration**: `setBridgeConfig()` to set the destination chain ID and staking contract address.
- **Fee estimation**: `estimateBridgeFee()` to check the LayerZero bridge cost before bridging.

These functions are deployed but not yet active. They will be enabled when the staking module launches.
