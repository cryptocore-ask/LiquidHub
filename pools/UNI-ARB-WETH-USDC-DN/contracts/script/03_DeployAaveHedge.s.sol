// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/AaveHedgeManager.sol";
import "../src/RangeManager.sol";
import "../src/MultiUserVault.sol";
import "../src/SecureBotModule.sol";

/// @title DeployAaveHedge - Deploy AaveHedgeManager + redeploy SecureBotModule + MultiUserVault
/// @dev Deploys all 3 contracts for the 75/25 DN strategy migration from Hyperliquid to AAVE V3
///      Usage: forge script script/03_DeployAaveHedge.s.sol:DeployAaveHedge --rpc-url $RPC_URL --broadcast --verify
contract DeployAaveHedge is Script {
    function run() external {
        // ===== ENVIRONMENT VARIABLES =====
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address botAddress = vm.envAddress("BOT_ADDRESS");

        // Tokens
        address token0 = vm.envAddress("TOKEN0_ADDRESS"); // WETH
        address token1 = vm.envAddress("TOKEN1_ADDRESS"); // USDC
        uint8 token0Decimals = uint8(vm.envUint("TOKEN0_DECIMALS"));
        uint8 token1Decimals = uint8(vm.envUint("TOKEN1_DECIMALS"));
        uint24 fee = uint24(vm.envUint("FEE"));
        uint256 commissionRate = vm.envUint("TAUX_PRELEV_PRCT") * 100;
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");

        // Config
        uint256 minDepositUSD = vm.envUint("MIN_DEPOSIT_USD");

        // AAVE V3 hedge reserve ratio (6250 = 62.5% for 75/25 strategy)
        uint16 hedgeReserveRatio = uint16(vm.envUint("AAVE_RESERVE_RATIO_BPS"));

        // AAVE V3 Pool on Arbitrum
        address aavePool = vm.envAddress("AAVE_POOL_ADDRESS");
        address variableDebtWeth = vm.envAddress("VARIABLE_DEBT_TOKEN0_ADDRESS");

        // Uniswap V3 SwapRouter for flash loan USDC→WETH swap
        address swapRouterAddress = vm.envAddress("SWAP_ROUTER_ADDRESS");
        uint24 swapPoolFee = fee; // Same fee tier as the LP pool

        // Uniswap V3
        address positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");

        // SecureBotModule config
        uint256 dailyLimit = vm.envUint("NBMAX_TRANS_DAY");

        // Swap config
        uint16 swapFeeBps = uint16(vm.envUint("SWAP_FEE_BPS"));
        uint256 initMultiSwapTvl = vm.envUint("INIT_MULTI_SWAP_TVL");

        // Dynamic Ranges config
        uint16 rangeUpPercent = uint16(vm.envUint("RANGE_UP_BASE") * 100);
        uint16 rangeDownPercent = uint16(vm.envUint("RANGE_DOWN_BASE") * 100);

        console.log("========================================");
        console.log("DEPLOYMENT: AAVE V3 HEDGE MIGRATION");
        console.log("========================================");
        console.log("Safe:", safeAddress);
        console.log("Bot:", botAddress);
        console.log("AAVE Pool:", aavePool);
        console.log("Hedge Reserve Ratio (bps):", hedgeReserveRatio);
        console.log("SwapRouter:", swapRouterAddress);
        console.log("Swap Pool Fee:", swapPoolFee);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // ===== 1. DEPLOY MULTIUSERVAULT =====
        console.log("1. Deploying MultiUserVault with 75/25 hedge reserve...");

        MultiUserVault vault = new MultiUserVault(
            address(1), // Placeholder for RangeManager
            token0,
            token1,
            treasuryAddress,
            commissionRate,
            minDepositUSD,
            hedgeReserveRatio // DN: 6250 = 62.5% reserved for AAVE collateral
        );

        console.log("   MultiUserVault deployed at:", address(vault));

        // ===== 2. DEPLOY AAVEHEDGEMANAGER =====
        console.log("\n2. Deploying AaveHedgeManager...");

        AaveHedgeManager hedgeManager = new AaveHedgeManager(
            safeAddress,
            address(vault), // vault immutable
            aavePool,
            token1, // USDC
            token0, // WETH
            variableDebtWeth,
            swapRouterAddress, // Uniswap V3 SwapRouter for flash loan swap
            swapPoolFee // fee tier for token1→token0 swap (500 = 0.05%)
        );

        console.log("   AaveHedgeManager deployed at:", address(hedgeManager));

        // ===== 3. DEPLOY RANGEMANAGER =====
        console.log("\n3. Deploying RangeManager...");

        RangeManager rangeManager = new RangeManager(
            address(vault),
            positionManager,
            factory,
            token0,
            token1,
            fee,
            token0Decimals,
            token1Decimals,
            swapRouterAddress,
            treasuryAddress,
            swapFeeBps,
            initMultiSwapTvl,
            rangeUpPercent,
            rangeDownPercent
        );

        console.log("   RangeManager deployed at:", address(rangeManager));

        // ===== 4. UPDATE VAULT WITH RANGEMANAGER + HEDGEMANAGER =====
        console.log("\n4. Updating Vault with RangeManager and HedgeManager...");
        vault.setRangeManager(address(rangeManager));
        vault.setHedgeManager(address(hedgeManager));
        console.log("   Vault updated with RangeManager and HedgeManager");

        // ===== 5. DEPLOY SECUREBOTMODULE =====
        console.log("\n5. Deploying SecureBotModule with hedge support...");

        SecureBotModule module = new SecureBotModule(
            safeAddress,
            botAddress,
            address(rangeManager),
            address(vault),
            address(hedgeManager),
            dailyLimit
        );

        console.log("   SecureBotModule deployed at:", address(module));

        // ===== 6. TRANSFER OWNERSHIP =====
        console.log("\n6. Post-deployment configuration...");
        vault.transferOwnership(safeAddress);
        console.log("   Vault ownership transferred to Safe");

        vm.stopBroadcast();

        // ===== 7. OUTPUT =====
        console.log("\n========================================");
        console.log(" DEPLOYMENT SUCCESSFUL!");
        console.log("========================================");
        console.log("\nAdd these to your .env file:\n");
        console.log(string.concat("AAVE_HEDGE_MANAGER_ADDRESS=", vm.toString(address(hedgeManager))));
        console.log(string.concat("VAULT_ADDRESS=", vm.toString(address(vault))));
        console.log(string.concat("RANGEMANAGER_ADDRESS=", vm.toString(address(rangeManager))));
        console.log(string.concat("SAFE_MODULE_ADDRESS=", vm.toString(address(module))));
        console.log("\nPost-deployment Safe transactions needed:");
        console.log("  1. Safe.disableModule(old module address)");
        console.log("  2. Safe.enableModule(", vm.toString(address(module)), ")");
        console.log("  3. vault.setBotModule(", vm.toString(address(module)), ")");
        console.log("  4. vault.authorizeExecutorOnRangeManager(", vm.toString(address(module)), ", true)");
        console.log("  5. vault.setupRangeManagerSafeAuthorization()");
        console.log(string.concat("  6. Add VARIABLE_DEBT_TOKEN0_ADDRESS=", vm.toString(variableDebtWeth), " to .env"));
        console.log("========================================\n");
    }
}
