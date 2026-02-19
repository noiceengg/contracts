// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    BundleParams,
    NumeraireCreatorAllocation,
    NumeraireLpUnlockTranche
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
        NumeraireCreatorAllocation[] memory noiceCreatorLocks = new NumeraireCreatorAllocation[](0);
        BundleParams memory params = _createBundleParams(noiceCreatorLocks);
        
        vm.prank(unauthorized);
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);
        assertNotEq(latestAsset, address(0));
        assertEq(launchpad.assetCreator(latestAsset), unauthorized, "Asset creator should be launch caller");
    }

    function test_CreatorCanWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NumeraireLpUnlockTranche[] memory tranches = new NumeraireLpUnlockTranche[](1);
        tranches[0] =
            NumeraireLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NumeraireCreatorAllocation[] memory noiceCreatorLocks = new NumeraireCreatorAllocation[](0);
        BundleParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        
        vm.prank(unauthorized);
        launchpad.bundleWithCreatorAllocations(params);
        latestAsset = _computeAssetAddress(params.createData.salt);

        vm.prank(unauthorized);
        launchpad.withdrawNumeraireLpUnlockPosition(latestAsset, 0, recipient1);
        assertTrue(launchpad.numeraireLpUnlockPositionWithdrawn(latestAsset, 0));
    }

    function test_RecipientCanWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NumeraireLpUnlockTranche[] memory tranches = new NumeraireLpUnlockTranche[](1);
        tranches[0] =
            NumeraireLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NumeraireCreatorAllocation[] memory noiceCreatorLocks = new NumeraireCreatorAllocation[](0);
        BundleParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        
        launchpad.bundleWithCreatorAllocations(params);
        latestAsset = _computeAssetAddress(params.createData.salt);

        vm.prank(recipient1);
        launchpad.withdrawNumeraireLpUnlockPosition(latestAsset, 0, recipient1);
        assertTrue(launchpad.numeraireLpUnlockPositionWithdrawn(latestAsset, 0));
    }

    function test_ExecutorCannotWithdrawUnlessCreatorOrRecipient() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NumeraireLpUnlockTranche[] memory tranches = new NumeraireLpUnlockTranche[](1);
        tranches[0] =
            NumeraireLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NumeraireCreatorAllocation[] memory noiceCreatorLocks = new NumeraireCreatorAllocation[](0);
        BundleParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        
        launchpad.bundleWithCreatorAllocations(params);
        latestAsset = _computeAssetAddress(params.createData.salt);

        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());

        vm.prank(executor);
        vm.expectRevert();
        launchpad.withdrawNumeraireLpUnlockPosition(latestAsset, 0, recipient1);
    }

    function test_ThirdPartyCannotWithdrawLpUnlock() public {
        uint256 unlockPercentage = 1000;
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        NumeraireLpUnlockTranche[] memory tranches = new NumeraireLpUnlockTranche[](1);
        tranches[0] =
            NumeraireLpUnlockTranche({ amount: tokenAmount, tickLower: 10_020, tickUpper: 19_980, recipient: recipient1 });

        NumeraireCreatorAllocation[] memory noiceCreatorLocks = new NumeraireCreatorAllocation[](0);
        BundleParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        
        launchpad.bundleWithCreatorAllocations(params);
        latestAsset = _computeAssetAddress(params.createData.salt);

        vm.prank(attacker);
        vm.expectRevert();
        launchpad.withdrawNumeraireLpUnlockPosition(latestAsset, 0, recipient1);
    }

    function test_OnlyOwnerCanCancelVestingStreams() public {
        NumeraireCreatorAllocation[] memory allocations = new NumeraireCreatorAllocation[](1);
        allocations[0] = NumeraireCreatorAllocation({
            recipient: recipient1,
            amount: 45_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(allocations);
        
        launchpad.bundleWithCreatorAllocations(params);
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
