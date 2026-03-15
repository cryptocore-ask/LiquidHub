// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/Treasury.sol";

contract DeployTreasury is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address usdc = vm.envAddress("TOKEN1_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        uint256 monthlyCap = vm.envUint("USDC_MONTHLY_CAP");
        bool bountyEnabled = vm.envBool("KEEPER_BOUNTY_ENABLED");
        uint256 bountyAmount = vm.envUint("KEEPER_BOUNTY_AMOUNT");
        address stargatePool = vm.envAddress("STARGATE_POOL_USDC");

        console.log("========================================");
        console.log("DEPLOYMENT: TREASURY (Stargate v2)");
        console.log("========================================");
        console.log("Safe:", safeAddress);
        console.log("USDC:", usdc);
        console.log("SwapRouter:", swapRouter);
        console.log("Monthly Cap (USDC):", monthlyCap);
        console.log("Bounty Enabled:", bountyEnabled);
        console.log("Bounty Amount:", bountyAmount);
        console.log("Stargate Pool USDC:", stargatePool);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        Treasury treasury = new Treasury(
            usdc,
            swapRouter,
            monthlyCap,
            bountyEnabled,
            bountyAmount,
            stargatePool
        );

        treasury.transferOwnership(safeAddress);

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log(" TREASURY DEPLOYMENT SUCCESSFUL!");
        console.log("========================================");
        console.log("\nAdd this to your .env file:\n");
        console.log(string.concat("TREASURY_ADDRESS=", vm.toString(address(treasury))));
        console.log("\nPost-deployment Safe transactions needed:");
        console.log("  1. treasury.authorizeRangeManager(RANGEMANAGER_ADDRESS, true)");
        console.log("  2. treasury.setBridgeConfig(true, BRIDGE_DESTINATION_EID, STAKING_ADDRESS_ON_BASE)");
        console.log("========================================\n");
    }
}
