// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import { BundleParams, NumeraireCreatorAllocation } from "src/NoiceLaunchpad.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { ISablierLockup } from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import { Lockup, LockupLinear, Broker } from "@sablier/v2-core/types/DataTypes.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";

/**
 * @title NoiceStreamCancellationTest
 * @notice Tests for cancelling Sablier vesting streams
 * @dev Tests both creator allocations and prebuy vesting cancellation
 */
contract NoiceStreamCancellationTest is NoiceBaseTest {
    address public founder = makeAddr("founder");
    address public advisor = makeAddr("advisor");
    address public attacker = makeAddr("attacker");
    address public latestAsset;

    function test_CancelStream_SingleCreatorStream() public {
        // Create stream
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Get stream ID from Sablier (streamId = nextStreamId - 1 after creation)
        uint256 streamId = sablierLockup.nextStreamId() - 1;

        // Verify stream exists and launchpad is sender
        assertEq(sablierLockup.getSender(streamId), address(launchpad));
        assertEq(sablierLockup.getRecipient(streamId), founder);
        assertFalse(sablierLockup.wasCanceled(streamId));

        // Cancel stream
        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = streamId;

        uint256 launchpadBalanceBefore = IERC20(latestAsset).balanceOf(address(launchpad));

        launchpad.cancelVestingStreams(streamIds);

        uint256 launchpadBalanceAfter = IERC20(latestAsset).balanceOf(address(launchpad));

        // Verify stream cancelled
        assertTrue(sablierLockup.wasCanceled(streamId));

        // Verify tokens refunded to launchpad
        assertGt(launchpadBalanceAfter, launchpadBalanceBefore);
    }

    function test_CancelStream_MultipleStreams() public {
        // Create multiple streams
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](3);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 27_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 730 days)
        });
        allocations[1] = NumeraireCreatorAllocation({
            recipient: advisor,
            amount: 13_500_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });
        allocations[2] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 4_500_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 180 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        uint256 firstStreamId = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Get all stream IDs (3 consecutive streams created)
        uint256[] memory streamIds = new uint256[](3);
        streamIds[0] = firstStreamId;
        streamIds[1] = firstStreamId + 1;
        streamIds[2] = firstStreamId + 2;

        // Verify all streams exist
        for (uint256 i = 0; i < 3; i++) {
            assertEq(sablierLockup.getSender(streamIds[i]), address(launchpad));
            assertFalse(sablierLockup.wasCanceled(streamIds[i]));
        }

        // Cancel all streams
        uint256 launchpadBalanceBefore = IERC20(latestAsset).balanceOf(address(launchpad));

        launchpad.cancelVestingStreams(streamIds);

        uint256 launchpadBalanceAfter = IERC20(latestAsset).balanceOf(address(launchpad));

        // Verify all streams cancelled
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(sablierLockup.wasCanceled(streamIds[i]));
        }

        // Verify tokens refunded
        assertGt(launchpadBalanceAfter, launchpadBalanceBefore);
    }

    function test_CancelStream_OnlyOwner() public {
        // Create stream
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);

        uint256 streamId = sablierLockup.nextStreamId() - 1;

        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = streamId;

        // Attacker tries to cancel
        vm.prank(attacker);
        vm.expectRevert();
        launchpad.cancelVestingStreams(streamIds);

        // Recipient tries to cancel
        vm.prank(founder);
        vm.expectRevert();
        launchpad.cancelVestingStreams(streamIds);

        // Owner can cancel
        launchpad.cancelVestingStreams(streamIds);

        assertTrue(sablierLockup.wasCanceled(streamId));
    }

    function test_CancelStream_NotSender() public {
        // Create stream from launchpad
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);

        uint256 ourStreamId = sablierLockup.nextStreamId() - 1;

        // Create another stream from different sender
        latestAsset = _computeAssetAddress(params.createData.salt);
        deal(latestAsset, attacker, 10_000e18);

        vm.startPrank(attacker);
        IERC20(latestAsset).approve(address(sablierLockup), 10_000e18);

        uint256 attackerStreamId = sablierLockup.createWithTimestampsLL(
            Lockup.CreateWithTimestamps({
                sender: attacker,
                recipient: founder,
                totalAmount: uint128(10_000e18),
                token: IERC20(latestAsset),
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({ start: uint40(block.timestamp), end: uint40(block.timestamp + 365 days) }),
                shape: "linear",
                broker: Broker(address(0), UD60x18.wrap(0))
            }),
            LockupLinear.UnlockAmounts({ start: 0, cliff: 0 }),
            0
        );
        vm.stopPrank();

        // Try to cancel attacker's stream
        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = attackerStreamId;

        // Sablier will revert because launchpad is not the stream sender
        // The actual error from Sablier on Base mainnet is a custom error (not a string)
        vm.expectRevert();
        launchpad.cancelVestingStreams(streamIds);
    }

    function test_CancelStream_CantCancelTwice() public {
        // Create stream
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);

        uint256 streamId = sablierLockup.nextStreamId() - 1;

        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = streamId;

        // Cancel first time
        launchpad.cancelVestingStreams(streamIds);

        assertTrue(sablierLockup.wasCanceled(streamId));

        // Try to cancel again - should revert from Sablier
        vm.prank(deployer);
        vm.expectRevert();
        launchpad.cancelVestingStreams(streamIds);
    }

    function test_CancelStream_RefundsToLaunchpad() public {
        // Create stream
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);
        uint256 streamId = sablierLockup.nextStreamId() - 1;

        // Wait some time
        vm.warp(block.timestamp + 30 days);

        // Check balances before cancel
        uint256 launchpadBefore = IERC20(latestAsset).balanceOf(address(launchpad));
        uint256 founderBefore = IERC20(latestAsset).balanceOf(founder);
        uint256 streamedAmount = sablierLockup.streamedAmountOf(streamId);

        // Cancel
        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = streamId;

        launchpad.cancelVestingStreams(streamIds);

        // Check balances after cancel
        uint256 launchpadAfter = IERC20(latestAsset).balanceOf(address(launchpad));
        uint256 founderAfter = IERC20(latestAsset).balanceOf(founder);

        // Verify:
        // - Launchpad receives unvested tokens
        // - Founder can still withdraw vested tokens (if they want)
        assertGt(launchpadAfter, launchpadBefore, "Launchpad should receive refund");
        assertEq(founderAfter, founderBefore, "Founder balance unchanged until withdraw");
    }

    function test_CancelStream_UseSweeepToRedistribute() public {
        // Create stream
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);
        uint256 streamId = sablierLockup.nextStreamId() - 1;

        // Cancel stream
        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = streamId;

        launchpad.cancelVestingStreams(streamIds);

        uint256 refundedAmount = IERC20(latestAsset).balanceOf(address(launchpad));

        // Use sweep to redistribute to deployer
        uint256 deployerBefore = IERC20(latestAsset).balanceOf(deployer);

        launchpad.sweep(latestAsset, deployer);

        uint256 deployerAfter = IERC20(latestAsset).balanceOf(deployer);

        // Verify tokens swept
        assertEq(deployerAfter - deployerBefore, refundedAmount);
        assertEq(IERC20(latestAsset).balanceOf(address(launchpad)), 0);
    }
}
