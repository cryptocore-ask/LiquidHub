#!/usr/bin/env node
/**
 * GenerateSafeBatch.js — Trading Service (GMX)
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
 *   1. Safe.enableModule(TRADING_BOT_MODULE_ADDRESS)
 *   2. TradingVault.setBotModule(TRADING_BOT_MODULE_ADDRESS)
 *   3. Treasury.authorizeRangeManager(TRADING_VAULT_ADDRESS, true)
 */

const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

// Charger le .env du service trading
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

function requireEnv(key) {
    const val = process.env[key];
    if (!val) {
        console.error(`❌ Variable manquante dans .env : ${key}`);
        process.exit(1);
    }
    return val;
}

// ===== ADRESSES DEPUIS .ENV =====
const CHAIN_ID = requireEnv('CHAIN_ID');
const SAFE_ADDRESS = requireEnv('SAFE_ADDRESS');
const TRADING_BOT_MODULE_ADDRESS = requireEnv('TRADING_BOT_MODULE_ADDRESS');
const TRADING_VAULT_ADDRESS = requireEnv('TRADING_VAULT_ADDRESS');
const TREASURY_ADDRESS = requireEnv('TREASURY_ADDRESS');

// ===== ABIS =====
const SAFE_ABI = ['function enableModule(address module)'];
const VAULT_ABI = ['function setBotModule(address _module)'];
const TREASURY_ABI = ['function authorizeRangeManager(address _rangeManager, bool _authorized)'];

// ===== ENCODER LES CALLDATA =====
const safeIface = new ethers.Interface(SAFE_ABI);
const vaultIface = new ethers.Interface(VAULT_ABI);
const treasuryIface = new ethers.Interface(TREASURY_ABI);

// ===== GÉNÉRER LE BATCH =====
const transactions = [
    {
        to: SAFE_ADDRESS,
        value: '0',
        data: safeIface.encodeFunctionData('enableModule', [TRADING_BOT_MODULE_ADDRESS]),
        contractMethod: {
            name: 'enableModule',
            inputs: [{ name: 'module', type: 'address' }],
        },
        contractInputsValues: {
            module: TRADING_BOT_MODULE_ADDRESS,
        },
    },
    {
        to: TRADING_VAULT_ADDRESS,
        value: '0',
        data: vaultIface.encodeFunctionData('setBotModule', [TRADING_BOT_MODULE_ADDRESS]),
        contractMethod: {
            name: 'setBotModule',
            inputs: [{ name: '_module', type: 'address' }],
        },
        contractInputsValues: {
            _module: TRADING_BOT_MODULE_ADDRESS,
        },
    },
    {
        to: TREASURY_ADDRESS,
        value: '0',
        data: treasuryIface.encodeFunctionData('authorizeRangeManager', [TRADING_VAULT_ADDRESS, true]),
        contractMethod: {
            name: 'authorizeRangeManager',
            inputs: [
                { name: '_rangeManager', type: 'address' },
                { name: '_authorized', type: 'bool' },
            ],
        },
        contractInputsValues: {
            _rangeManager: TRADING_VAULT_ADDRESS,
            _authorized: 'true',
        },
    },
];

// ===== FORMAT SAFE TRANSACTION BUILDER =====
const batch = {
    version: '1.0',
    chainId: CHAIN_ID,
    createdAt: Date.now(),
    meta: {
        name: 'Post-Deploy Configuration (Trading Service)',
        description: 'Enable module, configure vault, authorize treasury',
        txBuilderVersion: '1.16.5',
    },
    transactions,
};

// ===== ÉCRITURE DU FICHIER =====
const dirName = path.basename(path.join(__dirname, '..'));
const outputFile = path.join(__dirname, `safe-batch-${dirName.toLowerCase()}.json`);

fs.writeFileSync(outputFile, JSON.stringify(batch, null, 2));

console.log('\n========================================');
console.log(' SAFE BATCH GENERATED (Trading Service)');
console.log('========================================');
console.log(`\nFichier : ${outputFile}`);
console.log(`Chain ID : ${CHAIN_ID}`);
console.log(`Safe : ${SAFE_ADDRESS}`);
console.log(`\n${transactions.length} transactions :`);
console.log('  1. enableModule(', TRADING_BOT_MODULE_ADDRESS, ')');
console.log('  2. setBotModule(', TRADING_BOT_MODULE_ADDRESS, ')');
console.log('  3. authorizeRangeManager(', TRADING_VAULT_ADDRESS, ', true)');
console.log('\n→ Importer dans Safe > Transaction Builder > Upload batch');
console.log('========================================\n');
