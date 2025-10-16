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

/**
 * @title NoiceExecutorRoleTest
 * @notice Validates role-based access control for NoiceLaunchpad operations
 * @dev Ensures proper separation of duties between owner and executor roles:
 *      - Owner: Full administrative control (grant/revoke roles, cancel streams, execute operations)
 *      - Executor: Limited operational access (launch tokens, withdraw LP positions)
 *      - Unauthorized: No access to protected functions
 */
contract NoiceExecutorRoleTest is NoiceBaseTest {
    address public executor = makeAddr("executor");
    address public unauthorized = makeAddr("unauthorized");
    address public attacker = makeAddr("attacker");
    address public recipient1 = makeAddr("recipient1");
    address public latestAsset;

    /// @dev Verify test contract is properly configured as launchpad owner
    function test_OwnerIsTestContract() public view {
        assertEq(launchpad.owner(), address(this), "Test contract should be owner");
    }

    /// @dev Validate owner can grant executor role
    function test_OwnerCanGrantExecutorRole() public {
        assertFalse(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));

        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());

        assertTrue(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));
    }

    /// @dev Validate owner can revoke executor role
    function test_OwnerCanRevokeExecutorRole() public {
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());
        assertTrue(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));

        launchpad.revokeRoles(executor, launchpad.EXECUTOR_ROLE());

        assertFalse(launchpad.hasAnyRole(executor, launchpad.EXECUTOR_ROLE()));
    }

    /// @dev Executor role should permit token launches
    function test_ExecutorCanCallBundleWithCreatorVesting() public {
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(executor);
        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);
        assertNotEq(latestAsset, address(0));
    }

    /// @dev Owner should retain full operational access
    function test_OwnerCanCallBundleWithCreatorVesting() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);
        assertNotEq(latestAsset, address(0));
    }

    /// @dev Unauthorized addresses should be blocked from launching tokens
    function test_UnauthorizedCannotCallBundleWithCreatorVesting() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(unauthorized);
        vm.expectRevert();
        launchpad.bundleWithCreatorVesting(params, participants);
    }

    /// @dev Executor role should permit LP unlock withdrawals
    function test_ExecutorCanWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000; // 10%
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
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);

        assertTrue(launchpad.noiceLpUnlockPositionWithdrawn(latestAsset, 0));
    }

    /// @dev Owner should be able to withdraw LP unlock positions
    function test_OwnerCanWithdrawLpUnlock() public {
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

        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);

        assertTrue(launchpad.noiceLpUnlockPositionWithdrawn(latestAsset, 0));
    }

    /// @dev Unauthorized addresses should be blocked from LP unlock withdrawals
    function test_UnauthorizedCannotWithdrawLpUnlock() public {
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

        vm.prank(unauthorized);
        vm.expectRevert();
        launchpad.withdrawNoiceLpUnlockPosition(latestAsset, 0, recipient1);
    }

    /// @dev Stream cancellation should be restricted to owner only
    function test_OnlyOwnerCanCancelVestingStreams() public {
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());

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

        // Executor cannot cancel streams
        vm.prank(executor);
        vm.expectRevert();
        launchpad.cancelVestingStreams(streamIds);

        // Owner can cancel streams
        launchpad.cancelVestingStreams(streamIds);
        assertTrue(sablierLockup.wasCanceled(streamId));
    }

    /// @dev Revoked executors should lose operational access
    function test_RevokedExecutorCannotCallFunctions() public {
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());
        launchpad.revokeRoles(executor, launchpad.EXECUTOR_ROLE());

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(executor);
        vm.expectRevert();
        launchpad.bundleWithCreatorVesting(params, participants);
    }

    /// @dev Attacker without any role should be blocked
    function test_AttackerBlocked() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(attacker);
        vm.expectRevert();
        launchpad.bundleWithCreatorVesting(params, participants);
    }

    /// @dev Multiple unauthorized users should all be blocked
    function test_MultipleUnauthorizedUsersBlocked() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        address[] memory users = new address[](5);
        users[0] = makeAddr("user1");
        users[1] = makeAddr("user2");
        users[2] = makeAddr("user3");
        users[3] = makeAddr("user4");
        users[4] = makeAddr("user5");

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            vm.expectRevert();
            launchpad.bundleWithCreatorVesting(params, participants);
        }
    }
}
