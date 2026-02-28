# UNI-ARB-WETH-USDC Contracts (Standard Pool)

## Overview

Standard directional Uniswap V3 liquidity management for the WETH/USDC pair on Arbitrum. Users deposit into a shared vault, and a keeper bot manages concentrated liquidity positions -- rebalancing price ranges and collecting fees automatically.

## Contracts

| Contract | Description |
|---|---|
| **MultiUserVault.sol** | Multi-user vault handling deposits and withdrawals, LP position lifecycle management, and commission collection on earned fees. |
| **RangeManager.sol** | Price range management with on-chain swaps via Uniswap V3. Supports permissionless rebalancing triggered by the keeper bot. |
| **RangeOperations.sol** | Library for tick calculations and range operations used by RangeManager. |
| **SecureBotModule.sol** | Gnosis Safe module that restricts bot operations to a whitelist of approved function selectors, ensuring the bot can only call predefined vault/range functions. |
| **Treasury.sol** | Protocol fee collection contract. Handles keeper bounty payments and admin withdrawals with an enforced monthly cap. |

## Build

- **Compiler**: Solidity 0.8.19
- **Framework**: Foundry
- **Settings**: `via_ir = true`, `optimizer_runs = 200`

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V3 Core](https://github.com/Uniswap/v3-core)
- [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery)

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

# 3. Deploy Vault + RangeManager + SecureBotModule
forge script script/02_DeployContracts.s.sol:DeployContracts \
  --rpc-url $RPC_URL --broadcast --verify \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --libraries src/RangeOperations.sol:RangeOperations:$RANGE_OPERATIONS_LIB \
  -vvvv
# → Save VAULT_ADDRESS, RANGEMANAGER_ADDRESS, SAFE_MODULE_ADDRESS to .env
```

### Post-deployment Safe transactions

See [docs/SAFE-SETUP.md](../../../docs/SAFE-SETUP.md) for the full list of Gnosis Safe configuration commands.
