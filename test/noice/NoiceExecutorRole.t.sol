// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    BundleWithVestingParams,
    NoiceCreatorAllocation,
    NoicePrebuyParticipant,
    NoiceLpUnlockTranche
} from "src/NoiceLaunchpad.sol";

/**
 * @title NoiceExecutorRoleTest
 * @notice Validates access control after permissionless launch + creator-controlled SSLP changes
 */
contract NoiceExecutorRoleTest is NoiceBaseTest {
    address public executor = makeAddr("executor");
    address public unauthorized = makeAddr("unauthorized");
    address public attacker = makeAddr("attacker");
    address public recipient1 = makeAddr("recipient1");
    address public latestAsset;

    function test_OwnerIsTestContract() public view {
        assertEq(launchpad.owner(), address(this), "Test contract should be owner");
    }

    function test_OwnerCanGrantExecutorRole() public {
        assertFalse(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());
        assertTrue(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));
    }

    function test_OwnerCanRevokeExecutorRole() public {
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());
        assertTrue(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));
        launchpad.revokeRoles(executor, launchpad.EXECUTOR_ROLE());
        assertFalse(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));
    }

    function test_AnyAddressCanCallBundleWithCreatorVesting() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(unauthorized);
        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);
        assertNotEq(latestAsset, address(0));
        assertEq(launchpad.assetCreator(latestAsset), unauthorized, "Asset creator should be launch caller");
    }

    function test_CreatorCanWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] =
            NoiceLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(unauthorized);
        launchpad.bundleWithCreatorVesting(params, participants);
        latestAsset = _computeAssetAddress(params.createData.salt);

        vm.prank(unauthorized);
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);
        assertTrue(launchpad.noiceLpUnlockPositionWithdrawn(latestAsset, 0));
    }

    function test_RecipientCanWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] =
            NoiceLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);
        latestAsset = _computeAssetAddress(params.createData.salt);

        vm.prank(recipient1);
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);
        assertTrue(launchpad.noiceLpUnlockPositionWithdrawn(latestAsset, 0));
    }

    function test_ExecutorCannotWithdrawUnlessCreatorOrRecipient() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] =
            NoiceLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);
        latestAsset = _computeAssetAddress(params.createData.salt);

        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());

        vm.prank(executor);
        vm.expectRevert();
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);
    }

    function test_ThirdPartyCannotWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] =
            NoiceLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);
        latestAsset = _computeAssetAddress(params.createData.salt);

        vm.prank(attacker);
        vm.expectRevert();
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);
    }

    function test_OnlyOwnerCanCancelVestingStreams() public {
        NoiceCreatorAllocation[] memory allocations = new NoiceCreatorAllocation[](1);
        allocations[0] = NoiceCreatorAllocation({
            recipient: recipient1,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleWithVestingParams memory params = _createBundleParams(allocations);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);
        latestAsset = _computeAssetAddress(params.createData.salt);

        uint256 streamId = sablierLockup.nextStreamId() - 1;
        uint256[] memory streamIds = new uint256[](1);
        streamIds[0] = streamId;

        vm.prank(executor);
        vm.expectRevert();
        launchpad.cancelVestingStreams(streamIds);

        launchpad.cancelVestingStreams(streamIds);
        assertTrue(sablierLockup.wasCanceled(streamId));
    }
}
