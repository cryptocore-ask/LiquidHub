// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/RangeManager.sol";
import "../src/MultiUserVault.sol";
import "../src/SecureBotModule.sol";

contract DeployContracts is Script {
    function run() external {
        // ===== RÉCUPÉRATION VARIABLES ENVIRONNEMENT =====
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address botAddress = vm.envAddress("BOT_ADDRESS");
        address rangeOpsLib = vm.envAddress("RANGE_OPERATIONS_LIB"); // From step 1
        
        // Tokens
        address token0 = vm.envAddress("TOKEN0_ADDRESS");
        address token1 = vm.envAddress("TOKEN1_ADDRESS");
        uint8 token0Decimals = uint8(vm.envUint("TOKEN0_DECIMALS")); // 18
        uint8 token1Decimals = uint8(vm.envUint("TOKEN1_DECIMALS")); // 6
        uint24 fee = uint24(vm.envUint("FEE")); // 3000 for 0.3%
        uint256 commissionRate = vm.envUint("TAUX_PRELEV_PRCT") * 100; // Convertir en basis points
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");

        //Config
        uint256 minDepositUSD = vm.envUint("MIN_DEPOSIT_USD");

        // Uniswap V3
        address positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");

        // SecureBotModule config
        uint256 dailyLimit = vm.envUint("NBMAX_TRANS_DAY");

        // Swap config (Uniswap V3)
        address swapRouterAddress = vm.envAddress("SWAP_ROUTER_ADDRESS");
        uint16 swapFeeBps = uint16(vm.envUint("SWAP_FEE_BPS"));
        uint256 initMultiSwapTvl = vm.envUint("INIT_MULTI_SWAP_TVL");

        // Dynamic Ranges config (depuis .env)
        // RANGE_UP_BASE et RANGE_DOWN_BASE sont en % (ex: 1 = 1%)
        // On les convertit en basis points (1% = 100 bps)
        uint16 rangeUpPercent = uint16(vm.envUint("RANGE_UP_BASE") * 100);
        uint16 rangeDownPercent = uint16(vm.envUint("RANGE_DOWN_BASE") * 100);

        console.log("========================================");
        console.log("DEPLOYMENT CONFIGURATION");
        console.log("========================================");
        console.log("Safe:", safeAddress);
        console.log("Bot:", botAddress);
        console.log("Library:", rangeOpsLib);
        console.log("Token0 (WETH):", token0);
        console.log("Token1 (USDC):", token1);
        console.log("Pool fee:", fee);
        console.log("Range UP (bps):", rangeUpPercent);
        console.log("Range DOWN (bps):", rangeDownPercent);
        console.log("========================================\n");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // ===== 1. DÉPLOYER MULTIUSERVAULT =====
        console.log("1. Deploying MultiUserVault with time-weighted shares system...");

        MultiUserVault vault = new MultiUserVault(
            address(1), // Placeholder pour RangeManager
            token0,
            token1,
            treasuryAddress,
            commissionRate,
            minDepositUSD
        );

        console.log("   MultiUserVault deployed at:", address(vault));
        console.log("   Time-weighted shares system initialized");
        
        // ===== 2. DÉPLOYER RANGEMANAGER AVEC LIBRARY LINKÉE =====
        console.log("\n2. Deploying RangeManager with linked library...");

        // Deploy avec library linkée (Foundry gère le linking via --libraries flag)
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
        console.log("   SwapRouter approved:", swapRouterAddress);
        
        // ===== 3. METTRE À JOUR LE VAULT AVEC RANGEMANAGER =====
        console.log("\n3. Updating Vault with RangeManager address...");
        
        vault.setRangeManager(address(rangeManager));
        
        console.log("   Vault updated with RangeManager");
        
        // ===== 4. DÉPLOYER SECUREBOTMODULE =====
        console.log("\n4. Deploying SecureBotModule...");

        SecureBotModule module = new SecureBotModule(
            safeAddress,
            botAddress,
            address(rangeManager),
            address(vault),
            dailyLimit
        );

        console.log("   SecureBotModule deployed at:", address(module));
        console.log("   Daily transaction limit:", dailyLimit);
        
        // ===== 5. CONFIGURATION POST-DÉPLOIEMENT =====
        console.log("\n5. Post-deployment configuration...");
        
        // Transférer ownership du vault à la Safe
        vault.transferOwnership(safeAddress);
        console.log("   Vault ownership transferred to Safe");
        
        // Le RangeManager a déjà le vault comme owner via _transferOwnership dans constructor
        console.log("   RangeManager owner is Vault (set in constructor)");
                
        vm.stopBroadcast();
        
        // ===== 6. AFFICHAGE FINAL =====
        console.log("\n========================================");
        console.log(" DEPLOYMENT SUCCESSFUL!");
        console.log("========================================");
        console.log("\nAdd these to your .env file:\n");
        console.log(string.concat("VAULT_ADDRESS=", vm.toString(address(vault))));
        console.log(string.concat("RANGEMANAGER_ADDRESS=", vm.toString(address(rangeManager))));
        console.log(string.concat("SAFE_MODULE_ADDRESS=", vm.toString(address(module))));
        console.log("========================================\n");
    }
}