// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    NoiceLaunchpad,
    BundleWithVestingParams,
    NoiceCreatorAllocation,
    NoicePrebuyParticipant,
    NoiceLpUnlockTranche
} from "src/NoiceLaunchpad.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { ISablierLockup } from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import { ISablierBatchLockup } from "@sablier/v2-core/interfaces/ISablierBatchLockup.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { TeamGovernanceFactory } from "src/TeamGovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { TestMulticurveHook } from "./mocks/TestMulticurveHook.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Position } from "src/types/Position.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";

/**
 * @title NoiceLpUnlockIntegrationTest
 * @notice Integration test for LP unlock with custom hook that allows launchpad
 * @dev Uses TestMulticurveHook which whitelists both initializer and launchpad
 */
contract NoiceLpUnlockIntegrationTest is NoiceBaseTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public recipient1 = makeAddr("recipient1");
    address public recipient2 = makeAddr("recipient2");
    address public latestAsset;

    function test_LpUnlock_SingleTranche_Success() public {
        uint256 unlockPercentage = 1000; // 10%
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000; // 10B tokens

        // Define tick range
        int24 tickLower = 10_020; // Multiple of 60
        int24 tickUpper = 19_980; // Multiple of 60, below current tick

        // Create valid tranches - positions BELOW current tick (asset is token1, tick ~20040)
        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] = NoiceLpUnlockTranche({
            amount: tokenAmount,
            tickLower: tickLower,
            tickUpper: tickUpper,
            recipient: recipient1
        });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify position created
        uint256 positionCount = launchpad.getNoiceLpUnlockPositionCount(latestAsset);
        assertEq(positionCount, 1, "Should have 1 LP unlock position");

        Position[] memory positions = launchpad.getNoiceLpUnlockPositions(latestAsset);
        assertEq(positions.length, 1, "Should return 1 position");

        // Verify position details
        assertEq(positions[0].tickLower, tranches[0].tickLower, "Tick lower mismatch");
        assertEq(positions[0].tickUpper, tranches[0].tickUpper, "Tick upper mismatch");

        // Get pool key to query actual liquidity from PoolManager
        (,,,, IPoolInitializer poolInitializer,,,,,) = airlock.getAssetData(latestAsset);
        (,, PoolKey memory poolKey,) = UniswapV4MulticurveInitializer(address(poolInitializer)).getState(latestAsset);

        // Query actual liquidity owned by launchpad in this position
        (uint128 actualLiquidity,,) = poolManager.getPositionInfo(
            poolKey.toId(), address(launchpad), positions[0].tickLower, positions[0].tickUpper, positions[0].salt
        );

        // Verify launchpad owns liquidity in this position
        assertGt(actualLiquidity, 0, "Launchpad should own liquidity");
        // Verify stored liquidity matches actual liquidity in pool
        assertEq(positions[0].liquidity, actualLiquidity, "Stored liquidity should match actual");

        // Verify recipient mapping
        address storedRecipient = launchpad.noiceLpUnlockPositionRecipient(latestAsset, 0);
        assertEq(storedRecipient, recipient1, "Recipient mismatch");
    }

    function test_LpUnlock_MultipleTranches_Success() public {
        uint256 unlockPercentage = 1500; // 15%
        uint256 totalTokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000; // 15B tokens

        // Define tick ranges
        int24[3] memory tickLowers = [int24(15_000), int24(10_020), int24(5040)];
        int24[3] memory tickUppers = [int24(18_000), int24(13_980), int24(9000)];
        address[3] memory recipients = [recipient1, recipient2, recipient1];
        uint256[3] memory tokenShares = [uint256(40), 35, 25]; // Percentage shares

        // Create tranches with token amounts
        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 trancheTokenAmount = totalTokenAmount * tokenShares[i] / 100;

            tranches[i] = NoiceLpUnlockTranche({
                amount: trancheTokenAmount,
                tickLower: tickLowers[i],
                tickUpper: tickUppers[i],
                recipient: recipients[i]
            });
        }

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify 3 positions created
        uint256 positionCount = launchpad.getNoiceLpUnlockPositionCount(latestAsset);
        assertEq(positionCount, 3, "Should have 3 LP unlock positions");

        Position[] memory positions = launchpad.getNoiceLpUnlockPositions(latestAsset);
        assertEq(positions.length, 3, "Should return 3 positions");

        // Get pool key to query actual liquidity from PoolManager
        (,,,, IPoolInitializer poolInitializer,,,,,) = airlock.getAssetData(latestAsset);
        (,, PoolKey memory poolKey,) = UniswapV4MulticurveInitializer(address(poolInitializer)).getState(latestAsset);

        for (uint256 i = 0; i < 3; i++) {
            address storedRecipient = launchpad.noiceLpUnlockPositionRecipient(latestAsset, i);
            assertEq(storedRecipient, tranches[i].recipient, "Recipient mismatch");
            assertEq(positions[i].tickLower, tranches[i].tickLower, "Tick lower mismatch");
            assertEq(positions[i].tickUpper, tranches[i].tickUpper, "Tick upper mismatch");

            // Query actual liquidity owned by launchpad in this position
            (uint128 actualLiquidity,,) = poolManager.getPositionInfo(
                poolKey.toId(), address(launchpad), positions[i].tickLower, positions[i].tickUpper, positions[i].salt
            );

            // Verify launchpad owns liquidity
            assertGt(actualLiquidity, 0, "Launchpad should own liquidity");
            // Verify stored liquidity matches actual
            assertEq(positions[i].liquidity, actualLiquidity, "Stored liquidity should match actual");
        }
    }

    function test_LpUnlock_WithdrawalFlow() public {
        uint256 unlockPercentage = 1000; // 10%
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        // Define tick range
        int24 tickLower = 10_020;
        int24 tickUpper = 19_980;

        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] = NoiceLpUnlockTranche({
            amount: tokenAmount,
            tickLower: tickLower,
            tickUpper: tickUpper,
            recipient: recipient1
        });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Non-owner tries to withdraw
        vm.prank(recipient2);
        vm.expectRevert(); // Ownable revert
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);

        // Owner withdraws to recipient1
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);

        // Verify position marked as withdrawn
        bool isWithdrawn = launchpad.noiceLpUnlockPositionWithdrawn(latestAsset, 0);
        assertTrue(isWithdrawn, "Position should be marked as withdrawn");

        // Try to withdraw again - should fail
        vm.expectRevert("Already withdrawn");
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);
    }
}
