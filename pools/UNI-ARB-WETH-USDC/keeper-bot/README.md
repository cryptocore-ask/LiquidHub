# Liquid Hub Keeper Bot - Standard Pool

Keeper bot for the Liquid Hub Standard Pool (UNI-ARB-WETH-USDC). This bot monitors the RangeManager contract and executes rebalances when the current liquidity position goes out of range.

## How It Works

The keeper bot follows a simple loop:

1. Calls `getBotInstructions()` on the RangeManager contract
2. If `needsRebalance` is `true`, executes the appropriate action (`REBALANCE` or `MINT_INITIAL`)
3. Waits for the configured interval and repeats

### Rebalance Flow

When a rebalance is needed, the bot submits a single atomic transaction to `rebalance()` on the RangeManager. The contract performs all steps in one call:

1. **Lock vault** — prevents deposits/withdrawals during rebalance
2. **Burn old position** — removes liquidity and collects accrued fees
3. **Execute swaps** — rebalances token ratio for the new range. Large swaps are automatically split into N chunks ≤ `initMultiSwapTvl` (read from the contract).
4. **Mint new position** — creates a new position centered on the current price
5. **Unlock vault** — re-enables deposits/withdrawals
6. **Pay keeper bounty** — if bounty is enabled, USDC is sent to the keeper

Everything happens atomically: if any step fails, the whole transaction reverts and no partial state is left on-chain.

### Range Configuration

Ranges are configured **on-chain by the Safe multisig** (pool owner). The keeper bot does not set or modify ranges — it only executes rebalances when `getBotInstructions()` indicates one is needed.

### Permissionless

`rebalance()` is fully permissionless — any address can call it when the contract agrees a rebalance is needed. No whitelisting or keeper role required.

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
- **Funded wallet** — The keeper wallet needs ETH on Arbitrum for gas fees. Each rebalance is a single atomic transaction (the contract performs burn + swaps + mint internally).
- **No permission required** — `rebalance()` is public; any address can call it when a rebalance is needed.

## Security

The keeper bot is fully permissionless and operates with no special privileges:

- `rebalance()` is a public function — anyone can call it, but only when the contract agrees a rebalance is needed (`getBotInstructions()` returns `needsRebalance = true`)
- The keeper **cannot** access, transfer, or withdraw user funds
- The keeper **cannot** modify range parameters or pool configuration
- All privileged operations (range settings, fee parameters, emergency actions) are restricted to the Safe multisig
- Per-swap size is capped on-chain by `initMultiSwapTvl` to protect against slippage attacks

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
