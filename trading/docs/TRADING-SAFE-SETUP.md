# Trading Safe Setup

All post-deployment configuration transactions executed from the Gnosis Safe (2/3 multisig) via Safe UI → New Transaction → Contract Interaction.

---

## Step 1 — Enable Module on Safe

**Contract**: Safe (`SAFE_ADDRESS`)

```json
[{
    "name": "enableModule",
    "type": "function",
    "inputs": [{ "name": "module", "type": "address" }],
    "outputs": [],
    "stateMutability": "nonpayable"
}]
```

**Parameter**: `module` = `TRADING_BOT_MODULE_ADDRESS`

---

## Step 2 — Configure Module on TradingVault

**Contract**: TradingVault (`TRADING_VAULT_ADDRESS`)

```json
[{
    "name": "setBotModule",
    "type": "function",
    "inputs": [{ "name": "_module", "type": "address" }],
    "outputs": [],
    "stateMutability": "nonpayable"
}]
```

**Parameter**: `_module` = `TRADING_BOT_MODULE_ADDRESS`

---

## Step 3 — Authorize TradingVault on Treasury

**Contract**: Treasury (`TREASURY_ADDRESS`)

```json
[{
    "name": "authorizeRangeManager",
    "type": "function",
    "inputs": [
        { "name": "_rangeManager", "type": "address" },
        { "name": "_authorized", "type": "bool" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
}]
```

**Parameters**: `_rangeManager` = `TRADING_VAULT_ADDRESS`, `_authorized` = `true`

---

## Step 4 — Configure GMX Addresses on TradingVault (if not in constructor)

**Contract**: TradingVault

```json
[
    { "name": "setGmxExchangeRouter", "type": "function", "inputs": [{ "name": "_new", "type": "address" }], "outputs": [], "stateMutability": "nonpayable" },
    { "name": "setGmxReader", "type": "function", "inputs": [{ "name": "_new", "type": "address" }], "outputs": [], "stateMutability": "nonpayable" },
    { "name": "setGmxDataStore", "type": "function", "inputs": [{ "name": "_new", "type": "address" }], "outputs": [], "stateMutability": "nonpayable" }
]
```

**Values** (Arbitrum):
- `GMX_EXCHANGE_ROUTER`: `0x87d66368cD08a7Ca42252f5ab44B2fb6d1Fb8d15`
- `GMX_READER`: `0x5Ca84c34a381434786738735265b9f3FD814b824`
- `GMX_DATASTORE`: `0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8`

---

## Step 5 — Configure Commission and Treasury

**Contract**: TradingVault

```json
[
    { "name": "setCommissionRate", "type": "function", "inputs": [{ "name": "_rate", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" },
    { "name": "setTreasuryAddress", "type": "function", "inputs": [{ "name": "_treasury", "type": "address" }], "outputs": [], "stateMutability": "nonpayable" }
]
```

**Values**: `_rate` = `1000` (10%), `_treasury` = `TREASURY_ADDRESS`

---

## Step 6 — Configure On-Chain Risk Limits

**Contract**: TradingVault

```json
[
    { "name": "setMaxPositionSizeBps", "type": "function", "inputs": [{ "name": "_bps", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" },
    { "name": "setMaxTotalExposureBps", "type": "function", "inputs": [{ "name": "_bps", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" },
    { "name": "setMaxLeverage", "type": "function", "inputs": [{ "name": "_max", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" },
    { "name": "setMaxConcurrentPositions", "type": "function", "inputs": [{ "name": "_max", "type": "uint256" }], "outputs": [], "stateMutability": "nonpayable" }
]
```

**Values**:
- `_bps` (position size) = `500` (5%)
- `_bps` (total exposure) = `3000` (30%)
- `_max` (leverage) = `5`
- `_max` (concurrent positions) = `5`

---

## Step 7 (Optional — Later) — Enable Keeper Bounties

### On TradingVault:

```json
[{
    "name": "setKeeperBountyEnabled",
    "type": "function",
    "inputs": [{ "name": "_enabled", "type": "bool" }],
    "outputs": [],
    "stateMutability": "nonpayable"
}]
```

**Parameter**: `_enabled` = `true`

### On Treasury:

```json
[{
    "name": "setKeeperBounty",
    "type": "function",
    "inputs": [
        { "name": "_enabled", "type": "bool" },
        { "name": "_amount", "type": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
}]
```

**Parameters**: `_enabled` = `true`, `_amount` = `500000` (0.50 USDC, 6 decimals)

---

## Post-Setup Checklist

- [ ] Module enabled on Safe
- [ ] Module configured on TradingVault
- [ ] TradingVault authorized on Treasury
- [ ] GMX addresses set (or verified from constructor)
- [ ] Commission rate set
- [ ] Treasury address set
- [ ] Risk limits configured
- [ ] Bot wallet funded with ETH
- [ ] `.env` filled with deployed contract addresses
- [ ] `DEPLOYER_PRIVATE_KEY` and `ETHERSCAN_API_KEY` removed from `.env`
