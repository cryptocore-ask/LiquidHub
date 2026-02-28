// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/Treasury.sol";

contract DeployTreasury is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address token0 = vm.envAddress("TOKEN0_ADDRESS");
        address token1 = vm.envAddress("TOKEN1_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        uint24 fee = uint24(vm.envUint("FEE"));
        uint256 monthlyCap = vm.envUint("USDC_MONTHLY_CAP");
        bool bountyEnabled = vm.envBool("KEEPER_BOUNTY_ENABLED");
        uint256 bountyAmount = vm.envUint("KEEPER_BOUNTY_AMOUNT");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT_ADDRESS");

        console.log("========================================");
        console.log("DEPLOYMENT: TREASURY");
        console.log("========================================");
        console.log("Safe:", safeAddress);
        console.log("Token0 (WETH):", token0);
        console.log("Token1 (USDC):", token1);
        console.log("SwapRouter:", swapRouter);
        console.log("Pool Fee:", fee);
        console.log("Monthly Cap (USDC):", monthlyCap);
        console.log("Bounty Enabled:", bountyEnabled);
        console.log("Bounty Amount:", bountyAmount);
        console.log("LZ Endpoint:", lzEndpoint);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        Treasury treasury = new Treasury(
            token0,
            token1,
            swapRouter,
            fee,
            monthlyCap,
            bountyEnabled,
            bountyAmount,
            lzEndpoint
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
        console.log("========================================\n");
    }
}
