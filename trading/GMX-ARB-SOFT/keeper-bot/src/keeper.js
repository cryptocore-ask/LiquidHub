/**
 * GMX Trading Keeper Bot
 *
 * Monitors TradingVault positions and executes public functions:
 *   - executeStopLoss(key) when price hits SL
 *   - executeTakeProfit(key) when price hits TP
 *   - liquidatePosition(key) when collateral < maintenance margin
 *
 * Earns USDC bounty from Treasury when enabled.
 */

require('dotenv').config();
const { ethers } = require('ethers');

const TRADING_VAULT_ABI = [
    'function getActivePositionCount() view returns (uint256)',
    'function activePositionKeys(uint256 index) view returns (bytes32)',
    'function positions(bytes32 key) view returns (address market, bool isLong, uint256 collateralAmount, uint256 sizeInUsd, uint256 entryPrice, uint256 stopLossPrice, uint256 takeProfitPrice, uint256 openTimestamp, bool isOpen)',
    'function keeperBountyEnabled() view returns (bool)',
    'function gmxReader() view returns (address)',
    'function gmxDataStore() view returns (address)',
    'function executeStopLoss(bytes32 key) external',
    'function executeTakeProfit(bytes32 key) external',
    'function liquidatePosition(bytes32 key) external',
];

const GMX_READER_ABI = [
    'function getPosition(address dataStore, bytes32 key) view returns (tuple(tuple(address account, address market, address collateralToken) addresses, tuple(uint256 sizeInUsd, uint256 sizeInTokens, uint256 collateralAmount, uint256 borrowingFactor, uint256 fundingFeeAmountPerSize, uint256 longTokenClaimableFundingAmountPerSize, uint256 shortTokenClaimableFundingAmountPerSize, uint256 increasedAtBlock, uint256 decreasedAtBlock, uint256 increasedAtTime, uint256 decreasedAtTime) numbers, tuple(bool isLong) flags))',
];

const CHECK_INTERVAL = parseInt(process.env.CHECK_INTERVAL_MS || '30000');

async function main() {
    const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
    const wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
    const vault = new ethers.Contract(process.env.TRADING_VAULT_ADDRESS, TRADING_VAULT_ABI, wallet);

    console.log(`Keeper bot started`);
    console.log(`  Vault: ${process.env.TRADING_VAULT_ADDRESS}`);
    console.log(`  Keeper: ${wallet.address}`);
    console.log(`  Interval: ${CHECK_INTERVAL}ms`);

    const bountyEnabled = await vault.keeperBountyEnabled();
    console.log(`  Bounty: ${bountyEnabled ? 'ENABLED' : 'disabled'}`);

    while (true) {
        try {
            const count = await vault.getActivePositionCount();

            if (count > 0n) {
                const readerAddr = await vault.gmxReader();
                const dataStoreAddr = await vault.gmxDataStore();
                const reader = new ethers.Contract(readerAddr, GMX_READER_ABI, provider);

                for (let i = 0; i < Number(count); i++) {
                    const key = await vault.activePositionKeys(i);
                    const pos = await vault.positions(key);

                    if (!pos.isOpen) continue;

                    // Read GMX position
                    const gmxPos = await reader.getPosition(dataStoreAddr, key);
                    const sizeInUsd = gmxPos.numbers.sizeInUsd;
                    const sizeInTokens = gmxPos.numbers.sizeInTokens;
                    const collateral = gmxPos.numbers.collateralAmount;

                    if (sizeInTokens === 0n) continue;

                    // Approximate current price
                    const currentPrice = sizeInUsd * BigInt(1e18) / sizeInTokens;

                    // Check Stop Loss
                    if (pos.stopLossPrice > 0n) {
                        const slTriggered = pos.isLong
                            ? currentPrice <= pos.stopLossPrice
                            : currentPrice >= pos.stopLossPrice;

                        if (slTriggered) {
                            console.log(`SL triggered for key=${key.slice(0, 10)}... Executing...`);
                            try {
                                const tx = await vault.executeStopLoss(key, { gasLimit: 1_500_000 });
                                const receipt = await tx.wait();
                                console.log(`  SL executed: ${receipt.hash}`);
                            } catch (e) {
                                console.error(`  SL execution failed: ${e.message}`);
                            }
                            continue;
                        }
                    }

                    // Check Take Profit
                    if (pos.takeProfitPrice > 0n) {
                        const tpTriggered = pos.isLong
                            ? currentPrice >= pos.takeProfitPrice
                            : currentPrice <= pos.takeProfitPrice;

                        if (tpTriggered) {
                            console.log(`TP triggered for key=${key.slice(0, 10)}... Executing...`);
                            try {
                                const tx = await vault.executeTakeProfit(key, { gasLimit: 1_500_000 });
                                const receipt = await tx.wait();
                                console.log(`  TP executed: ${receipt.hash}`);
                            } catch (e) {
                                console.error(`  TP execution failed: ${e.message}`);
                            }
                            continue;
                        }
                    }

                    // Check Liquidation
                    if (collateral > 0n && sizeInUsd > 0n) {
                        const maintenanceMargin = sizeInUsd / 100n; // ~1%
                        if (collateral * BigInt(1e24) <= maintenanceMargin) {
                            console.log(`Liquidation condition for key=${key.slice(0, 10)}... Executing...`);
                            try {
                                const tx = await vault.liquidatePosition(key, { gasLimit: 1_500_000 });
                                const receipt = await tx.wait();
                                console.log(`  Liquidated: ${receipt.hash}`);
                            } catch (e) {
                                console.error(`  Liquidation failed: ${e.message}`);
                            }
                        }
                    }
                }
            }
        } catch (e) {
            console.error(`Check cycle error: ${e.message}`);
        }

        await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL));
    }
}

main().catch(err => {
    console.error('Keeper bot crash:', err);
    process.exit(1);
});
