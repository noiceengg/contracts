// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {NoiceLaunchpad} from "src/NoiceLaunchpad.sol";

/**
 * @title UnlockPositions
 * @notice Unlock all SSL LP positions and collect fees
 * @dev Set TOKEN_ADDRESS env var to the Oracle token address
 *
 *      Run with: forge script script/oracle/misc/sslp/UnlockPositions.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract UnlockPositions is Script {
    // Contract addresses
    address constant LAUNCHPAD = 0xdeeD48775805eEE22600371954dbeA3959Df1Aa5;
    address constant NOICE_TOKEN = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;

    NoiceLaunchpad public launchpad;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get token address from environment
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        console2.log("=== Unlock All SSL LP Positions ===");
        console2.log("Deployer:", deployer);
        console2.log("Token (Oracle):", tokenAddress);
        console2.log("NOICE:", NOICE_TOKEN);
        console2.log("NoiceLaunchpad:", LAUNCHPAD);
        console2.log("");

        launchpad = NoiceLaunchpad(payable(LAUNCHPAD));

        // We created 4 SSL positions
        uint256 totalPositions = 4;
        console2.log("Total LP unlock positions:", totalPositions);
        console2.log("");

        // Check initial balances
        uint256 tokenBefore = IERC20(tokenAddress).balanceOf(deployer);
        uint256 noiceBefore = IERC20(NOICE_TOKEN).balanceOf(deployer);
        console2.log("Initial Token balance:", tokenBefore / 1e18);
        console2.log("Initial NOICE balance:", noiceBefore / 1e18);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Unlock all positions
        for (uint256 i = 0; i < totalPositions; i++) {
            console2.log("--- Unlocking SSL Position", i, "---");

            // Record balances before this position unlock
            uint256 tokenBeforePos = IERC20(tokenAddress).balanceOf(deployer);
            uint256 noiceBeforePos = IERC20(NOICE_TOKEN).balanceOf(deployer);

            // Unlock position - this will:
            // 1. Collect any fees accumulated
            // 2. Withdraw the liquidity
            // 3. Transfer tokens to recipient
            launchpad.withdrawNoiceLpUnlockPosition(tokenAddress, i, deployer);

            // Record balances after this position unlock
            uint256 tokenAfterPos = IERC20(tokenAddress).balanceOf(deployer);
            uint256 noiceAfterPos = IERC20(NOICE_TOKEN).balanceOf(deployer);

            console2.log("Position", i, "unlocked successfully");
            console2.log("  Token gained:", (tokenAfterPos - tokenBeforePos) / 1e18);
            console2.log("  NOICE gained:", (noiceAfterPos - noiceBeforePos) / 1e18);
            console2.log("");
        }

        vm.stopBroadcast();

        // Check final balances
        uint256 tokenAfter = IERC20(tokenAddress).balanceOf(deployer);
        uint256 noiceAfter = IERC20(NOICE_TOKEN).balanceOf(deployer);

        console2.log("=== All Positions Unlocked ===");
        console2.log("Final Token balance:", tokenAfter / 1e18);
        console2.log("Final NOICE balance:", noiceAfter / 1e18);
        console2.log("");
        console2.log("Total Token gained:", (tokenAfter - tokenBefore) / 1e18);
        console2.log("Total NOICE gained:", (noiceAfter - noiceBefore) / 1e18);
        console2.log("");
        console2.log("Next: Run CollectFees.s.sol to collect multicurve fees");
    }
}
