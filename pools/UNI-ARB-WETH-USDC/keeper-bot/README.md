# Liquid Hub Keeper Bot - Standard Pool

Keeper bot for the Liquid Hub Standard Pool (UNI-ARB-WETH-USDC). This bot monitors the RangeManager contract and executes rebalances when the current liquidity position goes out of range.

## How It Works

The keeper bot follows a simple loop:

1. Calls `getBotInstructions()` on the RangeManager contract
2. If `needsRebalance` is `true`, executes the appropriate action (`REBALANCE` or `MINT_INITIAL`)
3. Waits for the configured interval and repeats

### Rebalance Flow

When a rebalance is needed, the bot executes the following on-chain transactions:

1. **Lock vault** - `startRebalance()` on MultiUserVault (prevents deposits/withdrawals during rebalance)
2. **Burn position** - `burnPosition(tokenId)` on RangeManager (removes liquidity and collects fees)
3. **Swap tokens** - `executeSwap()` on RangeManager (rebalances token ratio for the new range). Large swaps are automatically split into multiple chunks based on `INIT_MULTI_SWAP_TVL`.
4. **Mint position** - `mintInitialPosition()` on RangeManager (creates new position in the updated range)
5. **Unlock vault** - `endRebalance()` on MultiUserVault (re-enables deposits/withdrawals)

### Range Configuration

Ranges are configured **on-chain by the Safe multisig** (pool owner). The keeper bot does not set or modify ranges -- it only executes rebalances when the on-chain configuration indicates one is needed.

## Setup

### 1. Install dependencies

```bash
cd keeper-bot
npm install
```

### 2. Configure environment

Copy the example environment file and fill in your values:

```bash
cp ../.env.example .env
```

Edit `.env` with the following variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `RPC_URL` | Yes | Primary Arbitrum RPC endpoint |
| `RPC_BACKUP_1` | No | Backup RPC endpoint |
| `RPC_BACKUP_2` | No | Second backup RPC endpoint |
| `KEEPER_PRIVATE_KEY` | Yes* | Private key for the keeper wallet (*not needed for check-only mode) |
| `RANGEMANAGER_ADDRESS` | Yes | RangeManager contract address |
| `VAULT_ADDRESS` | Yes | MultiUserVault contract address |
| `TOKEN0_ADDRESS` | Yes | Token0 address (WETH) |
| `TOKEN1_ADDRESS` | Yes | Token1 address (USDC) |
| `TOKEN0_DECIMALS` | No | Token0 decimals (default: 18) |
| `TOKEN1_DECIMALS` | No | Token1 decimals (default: 6) |
| `CHECK_INTERVAL_MIN` | No | Check interval in minutes (default: 10) |
| `INIT_MULTI_SWAP_TVL` | No | Max USD value per swap chunk (default: 10000) |

### 3. Run the bot

**Active mode** (monitors and executes rebalances):

```bash
npm start
```

**Check-only mode** (reads status once, no transactions):

```bash
npm run check
```

## Keeper Bounty

If the pool's Treasury contract has `keeperBountyEnabled` set to `true`, the keeper wallet receives a USDC bounty for each successful rebalance. The bounty amount is configured by the Safe and can be queried via `keeperBountyAmount()` on the Treasury contract.

The bot displays bounty status on startup.

## Requirements

- **Node.js 18+**
- **Funded wallet** - The keeper wallet needs ETH on Arbitrum for gas fees. Typical rebalance costs 5-6 transactions.
- **Keeper role** - The wallet must be granted the keeper role on the RangeManager contract by the Safe.

## Security

The keeper bot operates with minimal permissions:

- It can **only** call whitelisted functions on the RangeManager and Vault contracts
- It **cannot** access, transfer, or withdraw user funds
- It **cannot** modify range parameters or pool configuration
- All privileged operations (range settings, fee parameters, emergency actions) are restricted to the Safe multisig
- The keeper role can be revoked at any time by the Safe

## Architecture

```
keeper-bot/
  src/
    keeper.js          # Main entry point and check loop
    rebalancer.js      # Rebalance execution logic (multi-step flow)
    utils/
      contracts.js     # Contract ABIs and factory
      rpc.js           # RPC provider pool with failover
```

## License

BUSL-1.1
