#!/usr/bin/env node
/**
 * GenerateSafeBatch.js — Pool Delta Neutral (AAVE V3)
 *
 * Génère un fichier JSON importable dans Safe Transaction Builder
 * contenant toutes les transactions post-déploiement.
 *
 * Usage :
 *   1. Mettre à jour le .env avec les nouvelles adresses déployées
 *   2. node script/GenerateSafeBatch.js
 *   3. Importer le fichier JSON généré dans Safe > Transaction Builder > Upload batch
 *   4. Vérifier les transactions > Create Batch > Send Batch
 *
 * Transactions générées :
 *   1. Safe.enableModule(SAFE_MODULE_ADDRESS)
 *   2. Vault.setBotModule(SAFE_MODULE_ADDRESS)
 *   3. Vault.authorizeExecutorOnRangeManager(SAFE_MODULE_ADDRESS, true)
 *   4. Vault.setupRangeManagerSafeAuthorization()
 *   5. Treasury.authorizeRangeManager(RANGEMANAGER_ADDRESS, true)
 *   6. RangeManager.configurePriceFeeds(token0Oracle, token1Oracle, ethOracle)
 */

const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

// Charger le .env de la pool
require('dotenv').config({ path: path.join(__dirname, '..', '.env'), override: true });

function requireEnv(key) {
    const val = process.env[key];
    if (!val) {
        console.error(`❌ Variable manquante dans .env : ${key}`);
        process.exit(1);
    }
    return val;
}

// ===== ADRESSES DEPUIS .ENV =====
const CHAIN_ID = requireEnv('CHAINID');
const SAFE_ADDRESS = requireEnv('SAFE_ADDRESS');
const SAFE_MODULE_ADDRESS = requireEnv('SAFE_MODULE_ADDRESS');
const VAULT_ADDRESS = requireEnv('VAULT_ADDRESS');
const RANGEMANAGER_ADDRESS = requireEnv('RANGEMANAGER_ADDRESS');
const TREASURY_ADDRESS = requireEnv('TREASURY_ADDRESS');
const TOKEN0_ORACLE = requireEnv('TOKEN0_ORACLE_ADDRESS');
const TOKEN1_ORACLE = requireEnv('TOKEN1_ORACLE_ADDRESS');
const ETH_ORACLE = requireEnv('ETH_ORACLE_ADDRESS');

// ===== ABIS =====
const SAFE_ABI = ['function enableModule(address module)'];
const VAULT_ABI = [
    'function setBotModule(address _module)',
    'function authorizeExecutorOnRangeManager(address executor, bool authorized)',
    'function setupRangeManagerSafeAuthorization()',
];
const TREASURY_ABI = [
    'function authorizeRangeManager(address _rangeManager, bool _authorized)',
];
const RANGEMANAGER_ABI = [
    'function configurePriceFeeds(address _token0PriceFeed, address _token1PriceFeed, address _ethPriceFeed)',
];

// ===== ENCODER LES CALLDATA =====
const safeIface = new ethers.Interface(SAFE_ABI);
const vaultIface = new ethers.Interface(VAULT_ABI);
const treasuryIface = new ethers.Interface(TREASURY_ABI);
const rmIface = new ethers.Interface(RANGEMANAGER_ABI);

// ===== GÉNÉRER LE BATCH =====
const transactions = [
    {
        to: SAFE_ADDRESS,
        value: '0',
        data: safeIface.encodeFunctionData('enableModule', [SAFE_MODULE_ADDRESS]),
        contractMethod: {
            name: 'enableModule',
            inputs: [{ name: 'module', type: 'address' }],
        },
        contractInputsValues: {
            module: SAFE_MODULE_ADDRESS,
        },
    },
    {
        to: VAULT_ADDRESS,
        value: '0',
        data: vaultIface.encodeFunctionData('setBotModule', [SAFE_MODULE_ADDRESS]),
        contractMethod: {
            name: 'setBotModule',
            inputs: [{ name: '_module', type: 'address' }],
        },
        contractInputsValues: {
            _module: SAFE_MODULE_ADDRESS,
        },
    },
    {
        to: VAULT_ADDRESS,
        value: '0',
        data: vaultIface.encodeFunctionData('authorizeExecutorOnRangeManager', [SAFE_MODULE_ADDRESS, true]),
        contractMethod: {
            name: 'authorizeExecutorOnRangeManager',
            inputs: [
                { name: 'executor', type: 'address' },
                { name: 'authorized', type: 'bool' },
            ],
        },
        contractInputsValues: {
            executor: SAFE_MODULE_ADDRESS,
            authorized: 'true',
        },
    },
    {
        to: VAULT_ADDRESS,
        value: '0',
        data: vaultIface.encodeFunctionData('setupRangeManagerSafeAuthorization'),
        contractMethod: {
            name: 'setupRangeManagerSafeAuthorization',
            inputs: [],
        },
        contractInputsValues: {},
    },
    {
        to: TREASURY_ADDRESS,
        value: '0',
        data: treasuryIface.encodeFunctionData('authorizeRangeManager', [RANGEMANAGER_ADDRESS, true]),
        contractMethod: {
            name: 'authorizeRangeManager',
            inputs: [
                { name: '_rangeManager', type: 'address' },
                { name: '_authorized', type: 'bool' },
            ],
        },
        contractInputsValues: {
            _rangeManager: RANGEMANAGER_ADDRESS,
            _authorized: 'true',
        },
    },
    {
        to: RANGEMANAGER_ADDRESS,
        value: '0',
        data: rmIface.encodeFunctionData('configurePriceFeeds', [TOKEN0_ORACLE, TOKEN1_ORACLE, ETH_ORACLE]),
        contractMethod: {
            name: 'configurePriceFeeds',
            inputs: [
                { name: '_token0PriceFeed', type: 'address' },
                { name: '_token1PriceFeed', type: 'address' },
                { name: '_ethPriceFeed', type: 'address' },
            ],
        },
        contractInputsValues: {
            _token0PriceFeed: TOKEN0_ORACLE,
            _token1PriceFeed: TOKEN1_ORACLE,
            _ethPriceFeed: ETH_ORACLE,
        },
    },
];

// ===== FORMAT SAFE TRANSACTION BUILDER =====
const batch = {
    version: '1.0',
    chainId: CHAIN_ID,
    createdAt: Date.now(),
    meta: {
        name: 'Post-Deploy Configuration (Delta Neutral Pool)',
        description: 'Enable module, authorize contracts, configure oracles',
        txBuilderVersion: '1.16.5',
    },
    transactions,
};

// ===== ÉCRITURE DU FICHIER =====
const poolName = process.env.RESEAU_BC_SHORT
    ? `${process.env.PROTOCOLE_SHORT}-${process.env.RESEAU_BC_SHORT}-${process.env.PAIR_TOKEN0}-${process.env.PAIR_TOKEN1}-DN`
    : 'pool-dn';
const outputFile = path.join(__dirname, `safe-batch-${poolName.toLowerCase()}.json`);

fs.writeFileSync(outputFile, JSON.stringify(batch, null, 2));

console.log('\n========================================');
console.log(' SAFE BATCH GENERATED (Delta Neutral)');
console.log('========================================');
console.log(`\nFichier : ${outputFile}`);
console.log(`Chain ID : ${CHAIN_ID}`);
console.log(`Safe : ${SAFE_ADDRESS}`);
console.log(`\n${transactions.length} transactions :`);
console.log('  1. enableModule(', SAFE_MODULE_ADDRESS, ')');
console.log('  2. setBotModule(', SAFE_MODULE_ADDRESS, ')');
console.log('  3. authorizeExecutorOnRangeManager(', SAFE_MODULE_ADDRESS, ', true)');
console.log('  4. setupRangeManagerSafeAuthorization()');
console.log('  5. authorizeRangeManager(', RANGEMANAGER_ADDRESS, ', true)');
console.log('  6. configurePriceFeeds(', TOKEN0_ORACLE, ',', TOKEN1_ORACLE, ',', ETH_ORACLE, ')');
console.log('\n→ Importer dans Safe > Transaction Builder > Upload batch');
console.log('========================================\n');
