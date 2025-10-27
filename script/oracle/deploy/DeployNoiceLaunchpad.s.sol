// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NoiceLaunchpad} from "src/NoiceLaunchpad.sol";
import {Airlock} from "src/Airlock.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";
import {ISablierLockup} from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import {ISablierBatchLockup} from "@sablier/v2-core/interfaces/ISablierBatchLockup.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";

/**
 * @title DeployNoiceLaunchpad
 * @notice Deploy NoiceLaunchpad contract on Base Mainnet
 * @dev Run with: forge script script/oracle/deploy/DeployNoiceLaunchpad.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY --verify
 */
contract DeployNoiceLaunchpad is Script {
    // Base Mainnet Production Contracts
    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant SABLIER_LOCKUP = 0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B;
    address constant SABLIER_BATCH_LOCKUP = 0xC26CdAFd6ec3c91AD9aEeB237Ee1f37205ED26a4;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function run() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Deploy NoiceLaunchpad ===");
        console2.log("Network: Base Mainnet");
        console2.log("Deployer:", deployer);
        console2.log("");
        console2.log("Deployment Parameters:");
        console2.log("  Airlock:", AIRLOCK);
        console2.log("  Universal Router:", UNIVERSAL_ROUTER);
        console2.log("  Sablier Lockup:", SABLIER_LOCKUP);
        console2.log("  Sablier Batch Lockup:", SABLIER_BATCH_LOCKUP);
        console2.log("  Pool Manager:", POOL_MANAGER);
        console2.log("  Owner:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        NoiceLaunchpad launchpad = new NoiceLaunchpad(
            Airlock(payable(AIRLOCK)),
            UniversalRouter(payable(UNIVERSAL_ROUTER)),
            ISablierLockup(SABLIER_LOCKUP),
            ISablierBatchLockup(SABLIER_BATCH_LOCKUP),
            IPoolManager(POOL_MANAGER),
            deployer
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("NoiceLaunchpad:", address(launchpad));
        console2.log("");
        console2.log("Next: Run GrantExecutorRole.s.sol to grant executor role");

        return address(launchpad);
    }
}
