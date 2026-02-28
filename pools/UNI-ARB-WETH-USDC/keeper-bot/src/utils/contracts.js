const { ethers } = require('ethers');

// RangeManager ABI (only functions needed by keeper)
const RANGEMANAGER_ABI = [
  "function getBotInstructions() external view returns (bool hasPosition, uint256 tokenId, bool needsRebalance, string memory action, string memory reason)",
  "function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut)",
  "function mintInitialPosition() external returns (uint256 tokenId, uint128 liquidity)",
  "function burnPosition(uint256 tokenId) external",
  "function getOptimalSwapParams() external view returns (tuple(bool swapNeeded, bool zeroForOne, uint256 amountIn, uint256 currentBalance0, uint256 currentBalance1, uint256 targetRatio0Bps, int24 tickLower, int24 tickUpper))",
  "function getPositionDetails(uint256 tokenId) external view returns (bool inRange, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)",
  "function priceCache() external view returns (uint128 price0, uint128 price1, uint160 poolSqrtPriceX96, int24 poolTick, uint64 timestamp, bool valid)",
  "function isSystemOperational() external view returns (bool)",
  "function config() external view returns (uint24 fee, uint8 token0Decimals, uint8 token1Decimals, uint16 toleranceBps, uint24 maxSlippageBps, uint64 lastRebalanceTime, bool oraclesConfigured, uint16 rangeUpPercent, uint16 rangeDownPercent, uint32 maxPositions)",
  "function initMultiSwapTvl() external view returns (uint256)"
];

// MultiUserVault ABI (only functions needed by keeper)
const VAULT_ABI = [
  "function startRebalance() external",
  "function endRebalance() external",
  "function isRebalancing() external view returns (bool)",
  "function treasuryAddress() external view returns (address)"
];

// Treasury ABI (for bounty info)
const TREASURY_ABI = [
  "function keeperBountyEnabled() external view returns (bool)",
  "function keeperBountyAmount() external view returns (uint256)"
];

function createContracts(provider) {
  const rangeManager = new ethers.Contract(
    process.env.RANGEMANAGER_ADDRESS,
    RANGEMANAGER_ABI,
    provider
  );
  const vault = new ethers.Contract(
    process.env.VAULT_ADDRESS,
    VAULT_ABI,
    provider
  );
  return { rangeManager, vault };
}

module.exports = { RANGEMANAGER_ABI, VAULT_ABI, TREASURY_ABI, createContracts };
