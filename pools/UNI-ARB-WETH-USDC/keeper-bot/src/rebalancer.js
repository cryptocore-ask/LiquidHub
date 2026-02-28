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
  constructor(rangeManager, vault, wallet) {
    this.rangeManager = rangeManager;
    this.vault = vault;
    this.wallet = wallet;
    this.rmConnected = this.rangeManager.connect(wallet);
    this.vaultConnected = this.vault.connect(wallet);
  }

  async executeRebalance(tokenId) {
    console.log(`\n=== Starting rebalance for position #${tokenId} ===`);
    const txHashes = [];

    try {
      // Step 1: Lock vault
      console.log('Step 1/6: Locking vault (startRebalance)...');
      const lockTx = await this.vaultConnected.startRebalance();
      await lockTx.wait();
      txHashes.push(lockTx.hash);
      console.log(`  Vault locked: ${lockTx.hash}`);

      // Step 2: Burn position
      console.log('Step 2/6: Burning position...');
      const burnTx = await this.rmConnected.burnPosition(tokenId);
      await burnTx.wait();
      txHashes.push(burnTx.hash);
      console.log(`  Position burned: ${burnTx.hash}`);
      await sleep(3000);

      // Step 3: Get optimal swap params
      console.log('Step 3/6: Calculating optimal swap...');
      const swapParams = await this.rangeManager.getOptimalSwapParams();

      if (swapParams.swapNeeded) {
        // Determine swap direction
        const token0 = process.env.TOKEN0_ADDRESS;
        const token1 = process.env.TOKEN1_ADDRESS;
        const tokenIn = swapParams.zeroForOne ? token0 : token1;
        const tokenOut = swapParams.zeroForOne ? token1 : token0;
        const amountIn = swapParams.amountIn;

        // Calculate number of swaps based on initMultiSwapTvl
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

        // Step 4: Execute swaps
        console.log(`Step 4/6: Executing ${numSwaps} swap(s) ($${amountUSD.toFixed(0)})...`);
        for (let i = 0; i < chunks.length; i++) {
          console.log(`  Swap ${i + 1}/${numSwaps}: ${ethers.formatUnits(chunks[i], decimals)} tokens`);
          const swapTx = await this.rmConnected.executeSwap(
            tokenIn,
            tokenOut,
            chunks[i],
            0n // minAmountOut=0, contract handles slippage
          );
          await swapTx.wait();
          txHashes.push(swapTx.hash);
          console.log(`  Swap ${i + 1} complete: ${swapTx.hash}`);
          if (i < chunks.length - 1) await sleep(2000);
        }
      } else {
        console.log('Step 4/6: No swap needed (already balanced)');
      }

      // Step 5: Mint new position
      console.log('Step 5/6: Minting new position...');
      const mintTx = await this.rmConnected.mintInitialPosition();
      const mintReceipt = await mintTx.wait();
      txHashes.push(mintTx.hash);
      console.log(`  New position minted: ${mintTx.hash}`);

      // Step 6: Unlock vault
      console.log('Step 6/6: Unlocking vault (endRebalance)...');
      const unlockTx = await this.vaultConnected.endRebalance();
      await unlockTx.wait();
      txHashes.push(unlockTx.hash);
      console.log(`  Vault unlocked: ${unlockTx.hash}`);

      console.log(`\n=== Rebalance complete (${txHashes.length} transactions) ===\n`);
      return { success: true, txHashes };

    } catch (error) {
      console.error(`Rebalance failed: ${error.message}`);

      // Try to unlock vault if it was locked
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
    console.log('\n=== Minting initial position ===');
    const txHashes = [];

    try {
      // Lock vault
      const lockTx = await this.vaultConnected.startRebalance();
      await lockTx.wait();
      txHashes.push(lockTx.hash);

      // Mint
      const mintTx = await this.rmConnected.mintInitialPosition();
      await mintTx.wait();
      txHashes.push(mintTx.hash);

      // Unlock
      const unlockTx = await this.vaultConnected.endRebalance();
      await unlockTx.wait();
      txHashes.push(unlockTx.hash);

      console.log('=== Mint complete ===\n');
      return { success: true, txHashes };
    } catch (error) {
      console.error(`Mint failed: ${error.message}`);
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
