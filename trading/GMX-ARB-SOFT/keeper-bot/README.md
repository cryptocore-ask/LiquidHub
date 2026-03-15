# GMX Trading Keeper Bot

Keeper bot for the Liquid Hub GMX v2 Trading system. Monitors positions and executes public functions when conditions are met.

## Functions

| Function | Trigger | Description |
|----------|---------|-------------|
| `executeStopLoss(key)` | Price hits stop-loss | Closes position at SL price |
| `executeTakeProfit(key)` | Price hits take-profit | Closes position at TP price |
| `liquidatePosition(key)` | Collateral < maintenance margin | Liquidates undercollateralized position |

## Bounty

When enabled by the protocol, keepers receive a USDC bounty from the Treasury for each successful execution. The bounty is configured via `Treasury.setKeeperBounty()`.

Bounties are **disabled by default** and can be enabled by the Safe multisig owner.

## Setup

```bash
npm install
cp .env.example .env
# Fill in RPC_URL and TRADING_VAULT_ADDRESS
node src/keeper.js
```

## Configuration

| Variable | Description |
|----------|-------------|
| `RPC_URL` | Arbitrum RPC endpoint |
| `TRADING_VAULT_ADDRESS` | TradingVault contract address |
| `KEEPER_PRIVATE_KEY` | Your wallet private key |
| `CHECK_INTERVAL_MS` | Check interval in ms (default: 30000) |
