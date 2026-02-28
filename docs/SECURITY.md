# Security Model

## Gnosis Safe Multisig (2/3)

The Gnosis Safe multisig is the root authority for all Liquid Hub contracts. It requires 2-of-3 signers for any transaction.

**Capabilities:**

- Controls all admin functions on all contracts
- Owner of `Treasury` and `MultiUserVault`
- Holds the "Authorized" role on `RangeManager`
- Can configure ranges, slippage tolerances, and oracle addresses
- Can enable/disable keeper bounty
- Can set the monthly withdrawal cap on Treasury
- Can permanently disable admin withdrawals (**irreversible**)

---

## SecureBotModule

The `SecureBotModule` is a Gnosis Safe module that whitelists specific function selectors, allowing a bot wallet to execute only pre-approved operations through the Safe.

**Whitelisted operations:**

- Rebalance steps: burn position, execute swap, mint position
- Process deposits
- Configure ranges

**Blocked operations (cannot be called via the module):**

- Transfer tokens
- Change ownership
- Withdraw from Treasury
- Any function not explicitly whitelisted

---

## Contract Permissions

### RangeManager

| Function | Access | Description |
|----------|--------|-------------|
| `executeSwap()` | Public | Anyone can call; only useful during an active rebalance |
| `mintInitialPosition()` | Public | Mints a new LP position |
| `burnPosition()` | Public | Burns the active position; tokens go to the vault |
| `configureRanges()` | `onlyAuthorized` | Safe or module only |
| `setSwapFeeBps()` | `onlyAuthorized` | Safe or module only |
| `setTreasuryAddress()` | `onlyAuthorized` | Safe or module only |

### Treasury

| Function | Access | Description |
|----------|--------|-------------|
| `swapToUSDC()` | Public | Converts WETH to USDC; tokens stay in Treasury |
| `adminWithdraw()` | `onlyOwner` (Safe) | Monthly cap enforced |
| `payKeeperBounty()` | Authorized RangeManagers only | Called automatically after rebalance |
| `disableAdminWithdraw()` | `onlyOwner` | **IRREVERSIBLE** |
| `setBridgeConfig()` | `onlyOwner` | Configure cross-chain bridge |
| `setKeeperBounty()` | `onlyOwner` | Enable/disable bounty and set amount |

### MultiUserVault

| Function | Access | Description |
|----------|--------|-------------|
| `deposit()` / `withdraw()` | Public | Any user can deposit or withdraw |
| `startRebalance()` / `endRebalance()` | `onlyBot` | Safe, module, or RangeManager |
| `collectCommissions()` | `onlyBot` | Collect LP fees for Treasury |
| `updateTreasuryAddress()` | `onlyOwner` (Safe) | Update the Treasury address |

---

## User Fund Safety

The protocol is designed so that user funds are protected even if the keeper wallet or bot infrastructure is compromised:

- **User funds are held in the vault contract**, never in the bot wallet or any externally owned account.
- **The keeper cannot withdraw user funds** — it can only call public rebalance functions.
- **LP position NFTs are owned by the vault contract**, not by any individual.
- **Withdrawals go directly to the user's wallet** — there is no intermediary step where funds can be redirected.
- **No admin can redirect user withdrawals** — the withdrawal function sends tokens to `msg.sender`.
- **The Safe multisig** provides an additional layer of protection: even admin operations require 2-of-3 signer approval.
