const { ethers } = require('ethers');

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function divideIntoChunks(totalAmount, numChunks) {
  if (numChunks <= 1) return [totalAmount];
  const chunks = [];
  const chunkSize = totalAmount / BigInt(numChunks);
  for (let i = 0; i < numChunks - 1; i++) {
    chunks.push(chunkSize);
  }
  chunks.push(totalAmount - chunkSize * BigInt(numChunks - 1));
  return chunks;
}

class Rebalancer {
  constructor(rangeManager, vault, hedgeManager, wallet) {
    this.rangeManager = rangeManager;
    this.vault = vault;
    this.hedgeManager = hedgeManager;
    this.wallet = wallet;
    this.rmConnected = this.rangeManager.connect(wallet);
    this.vaultConnected = this.vault.connect(wallet);
    this.hedgeConnected = hedgeManager ? hedgeManager.connect(wallet) : null;
  }

  async checkHedgeHealth() {
    if (!this.hedgeManager) return null;
    try {
      const hf = await this.hedgeManager.getHealthFactor();
      const hfFloat = Number(hf) / 1e18;
      const warnThreshold = parseFloat(process.env.AAVE_HEALTH_WARN || '1.25');
      const deleverageThreshold = parseFloat(process.env.AAVE_HEALTH_DELEVERAGE || '1.15');
      const emergencyThreshold = parseFloat(process.env.AAVE_HEALTH_EMERGENCY || '1.05');

      let status = 'OK';
      if (hfFloat < emergencyThreshold) status = 'EMERGENCY';
      else if (hfFloat < deleverageThreshold) status = 'DELEVERAGE';
      else if (hfFloat < warnThreshold) status = 'WARNING';

      return { healthFactor: hfFloat, status };
    } catch (e) {
      console.warn(`  Hedge health check failed: ${e.message}`);
      return null;
    }
  }

  async executeRebalance(tokenId) {
    console.log(`\n=== Starting DN rebalance for position #${tokenId} ===`);
    const txHashes = [];

    try {
      // Step 1: Lock vault
      console.log('Step 1/7: Locking vault (startRebalance)...');
      const lockTx = await this.vaultConnected.startRebalance();
      await lockTx.wait();
      txHashes.push(lockTx.hash);
      console.log(`  Vault locked: ${lockTx.hash}`);

      // Step 2: Burn position
      console.log('Step 2/7: Burning position...');
      const burnTx = await this.rmConnected.burnPosition(tokenId);
      await burnTx.wait();
      txHashes.push(burnTx.hash);
      console.log(`  Position burned: ${burnTx.hash}`);
      await sleep(3000);

      // Step 3: Check and recalibrate hedge (DN-specific)
      console.log('Step 3/7: Checking AAVE hedge...');
      const hedgeHealth = await this.checkHedgeHealth();
      if (hedgeHealth) {
        console.log(`  Health Factor: ${hedgeHealth.healthFactor.toFixed(4)} (${hedgeHealth.status})`);
        if (hedgeHealth.status === 'EMERGENCY') {
          console.log('  EMERGENCY: Health factor critically low, hedge needs attention');
        }
      }

      // Step 4: Get optimal swap params
      console.log('Step 4/7: Calculating optimal swap...');
      const swapParams = await this.rangeManager.getOptimalSwapParams();

      if (swapParams.swapNeeded) {
        const token0 = process.env.TOKEN0_ADDRESS;
        const token1 = process.env.TOKEN1_ADDRESS;
        const tokenIn = swapParams.zeroForOne ? token0 : token1;
        const tokenOut = swapParams.zeroForOne ? token1 : token0;
        const amountIn = swapParams.amountIn;

        const initMultiSwapTvl = parseInt(process.env.INIT_MULTI_SWAP_TVL || '100000', 10);
        const priceCache = await this.rangeManager.priceCache();
        const decimals = swapParams.zeroForOne
          ? parseInt(process.env.TOKEN0_DECIMALS || '18', 10)
          : parseInt(process.env.TOKEN1_DECIMALS || '6', 10);
        const price = swapParams.zeroForOne
          ? Number(priceCache.price0) / 1e8
          : Number(priceCache.price1) / 1e8;
        const amountUSD = parseFloat(ethers.formatUnits(amountIn, decimals)) * price;
        const numSwaps = Math.max(1, Math.ceil(amountUSD / initMultiSwapTvl));
        const chunks = divideIntoChunks(amountIn, numSwaps);

        console.log(`Step 5/7: Executing ${numSwaps} swap(s) ($${amountUSD.toFixed(0)})...`);
        for (let i = 0; i < chunks.length; i++) {
          console.log(`  Swap ${i + 1}/${numSwaps}: ${ethers.formatUnits(chunks[i], decimals)} tokens`);
          const swapTx = await this.rmConnected.executeSwap(tokenIn, tokenOut, chunks[i], 0n);
          await swapTx.wait();
          txHashes.push(swapTx.hash);
          console.log(`  Swap ${i + 1} complete: ${swapTx.hash}`);
          if (i < chunks.length - 1) await sleep(2000);
        }
      } else {
        console.log('Step 5/7: No swap needed');
      }

      // Step 6: Mint new position
      console.log('Step 6/7: Minting new position...');
      const mintTx = await this.rmConnected.mintInitialPosition();
      await mintTx.wait();
      txHashes.push(mintTx.hash);
      console.log(`  New position minted: ${mintTx.hash}`);

      // Step 7: Unlock vault
      console.log('Step 7/7: Unlocking vault (endRebalance)...');
      const unlockTx = await this.vaultConnected.endRebalance();
      await unlockTx.wait();
      txHashes.push(unlockTx.hash);
      console.log(`  Vault unlocked: ${unlockTx.hash}`);

      // Post-rebalance: verify hedge health
      const postHealth = await this.checkHedgeHealth();
      if (postHealth) {
        console.log(`  Post-rebalance Health Factor: ${postHealth.healthFactor.toFixed(4)} (${postHealth.status})`);
      }

      console.log(`\n=== DN Rebalance complete (${txHashes.length} transactions) ===\n`);
      return { success: true, txHashes };

    } catch (error) {
      console.error(`DN Rebalance failed: ${error.message}`);
      try {
        const isRebalancing = await this.vault.isRebalancing();
        if (isRebalancing) {
          console.log('Attempting to unlock vault...');
          const unlockTx = await this.vaultConnected.endRebalance();
          await unlockTx.wait();
          console.log('Vault unlocked after error');
        }
      } catch (unlockError) {
        console.error(`Failed to unlock vault: ${unlockError.message}`);
      }
      return { success: false, error: error.message, txHashes };
    }
  }

  async executeMint() {
    console.log('\n=== Minting initial DN position ===');
    const txHashes = [];
    try {
      const lockTx = await this.vaultConnected.startRebalance();
      await lockTx.wait();
      txHashes.push(lockTx.hash);

      const mintTx = await this.rmConnected.mintInitialPosition();
      await mintTx.wait();
      txHashes.push(mintTx.hash);

      const unlockTx = await this.vaultConnected.endRebalance();
      await unlockTx.wait();
      txHashes.push(unlockTx.hash);

      console.log('=== DN Mint complete ===\n');
      return { success: true, txHashes };
    } catch (error) {
      console.error(`DN Mint failed: ${error.message}`);
      try {
        const isRebalancing = await this.vault.isRebalancing();
        if (isRebalancing) {
          const unlockTx = await this.vaultConnected.endRebalance();
          await unlockTx.wait();
        }
      } catch (_) {}
      return { success: false, error: error.message, txHashes };
    }
  }
}

module.exports = { Rebalancer };
