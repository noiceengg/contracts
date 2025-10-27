// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {NoiceLaunchpad} from "src/NoiceLaunchpad.sol";

/**
 * @title GrantExecutorRole
 * @notice Grant executor role to an address on NoiceLaunchpad
 * @dev Run with: forge script script/oracle/deploy/GrantExecutorRole.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract GrantExecutorRole is Script {
    // NoiceLaunchpad address - update this after deployment
    address constant LAUNCHPAD = 0xdeeD48775805eEE22600371954dbeA3959Df1Aa5;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("=== Grant Executor Role ===");
        console.log("NoiceLaunchpad:", LAUNCHPAD);
        console.log("Granting to:", deployer);
        console.log("");

        NoiceLaunchpad launchpad = NoiceLaunchpad(payable(LAUNCHPAD));

        // Verify owner
        address launchpadOwner = launchpad.owner();
        console.log("Launchpad owner:", launchpadOwner);

        require(
            launchpadOwner == deployer,
            "Only owner can grant roles"
        );

        vm.startBroadcast(privateKey);

        launchpad.grantRoles(deployer, launchpad.EXECUTOR_ROLE());

        vm.stopBroadcast();

        console.log("");
        console.log("Executor role granted successfully!");
        console.log("");
        console.log("Next: Run LaunchOracle.s.sol to launch the token");
    }
}
