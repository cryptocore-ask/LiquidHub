// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/TradingBotModule.sol";

contract DeployTradingBotModule is Script {
    function run() external {
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address botAddress = vm.envAddress("BOT_ADDRESS");
        address tradingVault = vm.envAddress("TRADING_VAULT_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 dailyLimit = 50; // 50 transactions par jour par défaut

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        TradingBotModule module = new TradingBotModule(
            safeAddress,
            botAddress,
            tradingVault,
            treasury,
            dailyLimit
        );

        console.log("TradingBotModule deployed at:", address(module));

        vm.stopBroadcast();
    }
}
