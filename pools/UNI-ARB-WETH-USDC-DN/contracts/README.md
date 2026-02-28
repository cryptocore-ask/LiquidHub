# UNI-ARB-WETH-USDC-DN Contracts (Delta Neutral Pool)

## Overview

Delta neutral strategy combining Uniswap V3 concentrated liquidity with an AAVE V3 hedge on Arbitrum. This pool neutralizes directional ETH exposure by maintaining a short WETH position on AAVE that offsets the long WETH exposure from the Uniswap V3 LP position.

## Strategy

1. **Liquidity provision**: WETH and USDC are deployed into a Uniswap V3 concentrated liquidity position, earning trading fees.
2. **Hedge via AAVE V3**: A configurable reserve ratio (62.5%) of the pool's USDC is supplied as collateral on AAVE V3. WETH is borrowed against this collateral to hedge LP exposure.
3. **Atomic withdrawals**: When a user withdraws, the vault settles proportionally with the hedge manager. If the LP yields less WETH than the outstanding AAVE debt, a flash loan covers the shortfall -- the contract borrows WETH, repays the AAVE debt, withdraws USDC collateral, swaps USDC back to WETH via Uniswap V3 to repay the flash loan, and returns the remaining USDC to the vault for the user.

## Contracts

All contracts from the standard pool are included, plus the hedge manager:

| Contract | Description |
|---|---|
| **MultiUserVault.sol** | Multi-user vault handling deposits and withdrawals, LP position lifecycle management, and commission collection. Integrates with AaveHedgeManager for atomic delta-neutral withdrawals (flash loan + swap settlement). |
| **AaveHedgeManager.sol** | AAVE V3 integration for delta-neutral hedging. Manages collateral supply, WETH borrowing, proportional settlement on withdrawals using flash loans, and health factor monitoring. |
| **interfaces/IAaveV3Pool.sol** | Minimal AAVE V3 Pool interface used by AaveHedgeManager (supply, borrow, repay, withdraw, flashLoanSimple, getUserAccountData). |
| **RangeManager.sol** | Price range management with on-chain swaps via Uniswap V3. Supports permissionless rebalancing triggered by the keeper bot. |
| **RangeOperations.sol** | Library for tick calculations and range operations used by RangeManager. |
| **SecureBotModule.sol** | Gnosis Safe module that restricts bot operations to a whitelist of approved function selectors. |
| **Treasury.sol** | Protocol fee collection contract. Handles keeper bounty payments and admin withdrawals with an enforced monthly cap. |

## Build

- **Compiler**: Solidity 0.8.19
- **Framework**: Foundry
- **Settings**: `via_ir = true`, `optimizer_runs = 200`

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V3 Core](https://github.com/Uniswap/v3-core)
- [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery)
- [AAVE V3 Protocol](https://github.com/aave/aave-v3-core)

## Key Difference from Standard Pool

The standard pool's `MultiUserVault` handles deposits and withdrawals directly against the Uniswap V3 position. In the delta neutral variant, the vault coordinates with `AaveHedgeManager` to atomically unwind both the LP position and the AAVE hedge during withdrawals. This ensures users receive their fair share of both LP assets and hedge collateral in a single transaction, using flash loans and Uniswap V3 swaps when necessary to cover any WETH shortfall.

## Deployment

These contracts are deployed on **Arbitrum** (chainId `42161`).

### Deployment Order

Deploy scripts are in `script/`. They must be run in this order:

```bash
# 1. Deploy RangeOperations library
forge script script/01_DeployLibrary.s.sol:DeployLibrary \
  --rpc-url $RPC_URL --broadcast --verify \
  --etherscan-api-key $ARBISCAN_API_KEY -vvvv
# → Save RANGE_OPERATIONS_LIB=0x... to .env

# 2. Deploy Treasury (needed by Vault and RangeManager constructors)
forge script script/Deploy_Treasury.s.sol:DeployTreasury \
  --rpc-url $RPC_URL --broadcast --verify \
  --etherscan-api-key $ARBISCAN_API_KEY -vvvv
# → Save TREASURY_ADDRESS=0x... to .env

# 3. Deploy Vault + AaveHedgeManager + RangeManager + SecureBotModule
forge script script/03_DeployAaveHedge.s.sol:DeployAaveHedge \
  --rpc-url $RPC_URL --broadcast --verify \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --libraries src/RangeOperations.sol:RangeOperations:$RANGE_OPERATIONS_LIB \
  -vvvv
# → Save VAULT_ADDRESS, AAVE_HEDGE_MANAGER_ADDRESS, RANGEMANAGER_ADDRESS, SAFE_MODULE_ADDRESS to .env
```

### Post-deployment Safe transactions

See [docs/SAFE-SETUP.md](../../../docs/SAFE-SETUP.md) for the full list of Gnosis Safe configuration commands.
