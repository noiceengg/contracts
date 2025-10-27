// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

interface ISablierLockup {
    function withdrawMax(uint256 streamId, address to) external returns (uint128 withdrawnAmount);
    function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);
    function getRecipient(uint256 streamId) external view returns (address recipient);
    function getAsset(uint256 streamId) external view returns (address asset);
}

/**
 * @title UnlockVesting
 * @notice Utility to withdraw from Sablier vesting streams (prebuy & creator vesting)
 * @dev Takes recipient address and stream IDs as arguments
 *
 *      Usage:
 *      1. Set RECIPIENT_ADDRESS env var (address that receives the vested tokens)
 *      2. Set STREAM_IDS env var (comma-separated list, e.g., "15253,15254")
 *      3. Run: forge script script/oracle/misc/utils/UnlockVesting.s.sol \
 *         --rpc-url $BASE_MAINNET_RPC_URL \
 *         --broadcast --private-key $PRIVATE_KEY
 *
 *      Alternative: Pass stream IDs directly via forge script args
 */
contract UnlockVesting is Script {
    // Base Mainnet Sablier address
    address constant SABLIER_LOCKUP = 0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B;

    ISablierLockup public sablier;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address executor = vm.addr(privateKey);

        // Get recipient address from env
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");

        console2.log("=== Unlock Vesting Streams ===");
        console2.log("Executor:", executor);
        console2.log("Recipient:", recipient);
        console2.log("Sablier:", SABLIER_LOCKUP);
        console2.log("");

        sablier = ISablierLockup(SABLIER_LOCKUP);

        // Get stream IDs from env (comma-separated)
        string memory streamIdsStr = vm.envString("STREAM_IDS");
        uint256[] memory streamIds = parseStreamIds(streamIdsStr);

        console2.log("Total streams to process:", streamIds.length);
        console2.log("");

        vm.startBroadcast(privateKey);

        uint256 totalWithdrawn = 0;
        address assetAddress;

        for (uint256 i = 0; i < streamIds.length; i++) {
            uint256 streamId = streamIds[i];
            console2.log("--- Processing Stream", streamId, "---");

            // Get stream info
            address streamRecipient = sablier.getRecipient(streamId);
            address asset = sablier.getAsset(streamId);
            uint128 withdrawable = sablier.withdrawableAmountOf(streamId);

            console2.log("  Stream recipient:", streamRecipient);
            console2.log("  Asset:", asset);
            console2.log("  Withdrawable amount:", withdrawable / 1e18);

            require(streamRecipient == recipient, "Stream recipient mismatch");

            if (assetAddress == address(0)) {
                assetAddress = asset;
            } else {
                require(assetAddress == asset, "All streams must have same asset");
            }

            if (withdrawable > 0) {
                // Withdraw to recipient
                uint128 withdrawn = sablier.withdrawMax(streamId, recipient);
                console2.log("  Withdrawn:", withdrawn / 1e18);
                totalWithdrawn += withdrawn;
            } else {
                console2.log("  Nothing to withdraw yet");
            }

            console2.log("");
        }

        vm.stopBroadcast();

        console2.log("=== Vesting Unlock Complete ===");
        console2.log("Total withdrawn:", totalWithdrawn / 1e18);
        console2.log("Asset:", assetAddress);

        if (assetAddress != address(0)) {
            uint256 finalBalance = IERC20(assetAddress).balanceOf(recipient);
            console2.log("Recipient final balance:", finalBalance / 1e18);
        }
    }

    /**
     * @dev Parse comma-separated stream IDs from string
     * @param streamIdsStr Comma-separated string of stream IDs (e.g., "15253,15254")
     * @return Array of parsed stream IDs
     */
    function parseStreamIds(string memory streamIdsStr) internal pure returns (uint256[] memory) {
        bytes memory streamIdsBytes = bytes(streamIdsStr);

        // Count commas to determine array size
        uint256 count = 1;
        for (uint256 i = 0; i < streamIdsBytes.length; i++) {
            if (streamIdsBytes[i] == ",") {
                count++;
            }
        }

        uint256[] memory streamIds = new uint256[](count);
        uint256 currentIndex = 0;
        uint256 currentNumber = 0;
        uint256 arrayIndex = 0;

        for (uint256 i = 0; i < streamIdsBytes.length; i++) {
            bytes1 char = streamIdsBytes[i];

            if (char == ",") {
                streamIds[arrayIndex++] = currentNumber;
                currentNumber = 0;
            } else if (char >= "0" && char <= "9") {
                currentNumber = currentNumber * 10 + (uint8(char) - uint8(bytes1("0")));
            }
        }

        // Add the last number
        if (streamIdsBytes.length > 0) {
            streamIds[arrayIndex] = currentNumber;
        }

        return streamIds;
    }
}
