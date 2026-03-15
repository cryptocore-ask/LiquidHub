// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "../src/TradingVault.sol";

contract DeployTradingVault is Script {
    function run() external {
        // Lire les variables d'environnement
        address usdc = vm.envAddress("USDC_ADDRESS");
        address gmxExchangeRouter = vm.envAddress("GMX_EXCHANGE_ROUTER");
        address gmxOrderVault = vm.envAddress("GMX_ORDER_VAULT");
        address gmxReader = vm.envAddress("GMX_READER");
        address gmxDataStore = vm.envAddress("GMX_DATASTORE");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 commissionRate = vm.envUint("COMMISSION_RATE_BPS");

        // Risk management — valeurs initiales on-chain lues depuis .env
        uint256 maxPositionSizeBps = vm.envUint("MAX_POSITION_SIZE_PERCENT") * 100; // 5 → 500 bps
        uint256 maxTotalExposureBps = vm.envUint("MAX_TOTAL_EXPOSURE_PERCENT") * 100; // 30 → 3000 bps
        uint256 maxLeverage = vm.envUint("MAX_LEVERAGE");
        uint256 maxConcurrentPositions = vm.envUint("MAX_CONCURRENT_POSITIONS");
        uint256 minDeposit = vm.envUint("MIN_DEPOSIT");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        TradingVault vault = new TradingVault(
            usdc,
            gmxExchangeRouter,
            gmxOrderVault,
            gmxReader,
            gmxDataStore,
            treasury,
            commissionRate,
            maxPositionSizeBps,
            maxTotalExposureBps,
            maxLeverage,
            maxConcurrentPositions,
            minDeposit
        );

        console.log("TradingVault deployed at:", address(vault));

        // Configurer depositCooldown depuis .env (avant transferOwnership)
        uint256 depositCooldown = vm.envUint("DEPOSIT_COOLDOWN");
        if (depositCooldown != 1 hours) {
            vault.setDepositCooldown(depositCooldown);
            console.log("Deposit cooldown set to:", depositCooldown);
        }

        // Transférer ownership à la Safe
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        vault.transferOwnership(safeAddress);
        console.log("Ownership transferred to Safe:", safeAddress);

        vm.stopBroadcast();
    }
}
