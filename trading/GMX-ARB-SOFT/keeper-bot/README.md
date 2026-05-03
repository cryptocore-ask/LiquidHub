# GMX Trading Keeper Bot

Keeper bot for the Liquid Hub GMX v2 Trading system. Monitors positions using **Chainlink on-chain price feeds** and executes public vault functions when conditions are met.

## Functions

| Function | Trigger | Authorization | Description |
|----------|---------|---------------|-------------|
| `executeStopLoss(key)` | Price hits SL **and** bot has authorized | Bot must call `authorizeClosure(key, 1)` first | Closes position at SL price |
| `executeTakeProfit(key)` | Price hits TP **and** bot has authorized | Bot must call `authorizeClosure(key, 2)` first | Closes position at TP price |
| `liquidatePosition(key)` | Collateral < maintenance margin | Permissionless (safety net) | Liquidates undercollateralized position |
| `settleAll()` | Pending settlements exist | Permissionless | Collects protocol commissions on profitable trades |

## Price Source

Prices are read from **Chainlink price feeds on Arbitrum** (not Binance or CoinGecko). Only tokens with a verified Chainlink feed and a deviation threshold ≤ 1% are monitored.

## SL/TP Logic

SL and TP percentages are **on the collateral** (PnL), not on the raw price movement. They are automatically adjusted for leverage:

- `DEFAULT_STOP_LOSS_PERCENT=4` with 2x leverage → triggers at 2% price movement → 4% collateral loss
- `DEFAULT_TAKE_PROFIT_PERCENT=8` with 3x leverage → triggers at 2.67% price movement → 8% collateral profit

## Closure Authorization

The vault uses a **bot-authorized, public-executed** closure model. For each position, the protocol bot runs its own off-chain logic (technical analysis, AI signals, macro context, etc.) and authorizes closure via `authorizeClosure(key, closureType)` on the vault.

This opens a **~1 minute window** during which community keepers (you) can execute `executeStopLoss` or `executeTakeProfit` on the position and earn the bounty. After the window expires, the protocol bot closes the position itself as a fallback.

As a keeper, your job is simple:

1. Listen for `ClosureAuthorized(key, closureType, expiresAt)` events on the vault (or poll `isClosureAuthorized(key, type)`)
2. Verify the SL/TP price condition is met
3. Submit `executeStopLoss(key)` or `executeTakeProfit(key)` — first keeper wins the bounty

The keeper bot handles all of this automatically.

## Commissions

The keeper calls `settleAll()` every 5 minutes to settle pending commissions. When a position is closed with profit, the vault automatically sends the protocol commission (configured via `COMMISSION_RATE_BPS`) in USDC to the Treasury address.

## Bounty

When enabled by the protocol, keepers receive a USDC bounty from the Treasury for each successful SL/TP/liquidation execution. The bounty is configured via `Treasury.setKeeperBounty()`.

Bounties are **disabled by default** and can be enabled by the Safe multisig owner.

## Setup

```bash
npm install
cp .env.example .env
# Fill in RPC_URL, TRADING_VAULT_ADDRESS and KEEPER_PRIVATE_KEY
node src/keeper.js
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `RPC_URL` | Arbitrum RPC endpoint | - |
| `TRADING_VAULT_ADDRESS` | TradingVault contract address | - |
| `KEEPER_PRIVATE_KEY` | Your wallet private key | - |
| `CHECK_INTERVAL_MS` | Check interval in ms | 30000 |
| `EXECUTION_FEE` | ETH execution fee per GMX order | 0.0002 |
| `DEFAULT_STOP_LOSS_PERCENT` | Stop loss % on collateral | 4 |
| `DEFAULT_TAKE_PROFIT_PERCENT` | Take profit % on collateral | 8 |
| `ULTIM_SHORT_STOP_LOSS_ENABLED` | Force-close SHORTs losing more than N% vs entry (safety cap) | false |
| `ULTIM_SHORT_STOP_LOSS_PERCENT` | Max % move against a SHORT before force-close | 20 |
