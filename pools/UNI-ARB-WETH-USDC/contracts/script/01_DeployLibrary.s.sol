// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/RangeOperations.sol";

contract DeployLibrary is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("========================================");
        console.log("Deploying RangeOperations library...");
        console.log("========================================");
        
        // Déployer la library avec CREATE
        bytes memory bytecode = vm.getCode("RangeOperations.sol:RangeOperations");
        address rangeOpsLib;
        assembly {
            rangeOpsLib := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        
        console.log(" RangeOperations deployed at:", rangeOpsLib);
        console.log("\nSAVE THIS ADDRESS FOR NEXT STEP!");
        console.log("Add to .env file:");
        console.log(string.concat("RANGE_OPERATIONS_LIB=", vm.toString(rangeOpsLib)));
        
        vm.stopBroadcast();
    }
}