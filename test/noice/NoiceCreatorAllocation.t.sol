// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    BundleParams,
    NumeraireCreatorAllocation,
    NumeraireLpUnlockTranche
} from "src/NoiceLaunchpad.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title NumeraireCreatorAllocationTest
 * @notice Tests creator token allocations with Sablier vesting integration
 * @dev Validates Sablier stream creation, vesting schedules, and withdrawals
 */
contract NumeraireCreatorAllocationTest is NoiceBaseTest {
    address public latestAsset;

    function test_CreatorAllocation_SingleRecipient_VerifySablier() public {
        address recipient = makeAddr("founder");
        uint256 lockAmount = 45_000_000_000e18; // 45B tokens (45%)

        NumeraireCreatorAllocation[] memory locks = new NumeraireCreatorAllocation[](1);
        locks[0] = NumeraireCreatorAllocation({
            recipient: recipient,
            amount: lockAmount,
            lockStartTimestamp: uint40(block.timestamp + 1 days),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(locks);
        
        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify stream created
        uint256 streamId = nextStreamIdBefore;
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(nextStreamIdAfter, nextStreamIdBefore + 1, "Should create 1 stream");

        // Verify Sablier stream properties
        address streamRecipient = sablierLockup.getRecipient(streamId);
        assertEq(streamRecipient, recipient, "Recipient mismatch");

        uint256 depositedAmount = sablierLockup.getDepositedAmount(streamId);
        assertEq(depositedAmount, lockAmount, "Deposited amount mismatch");

        address sender = sablierLockup.getSender(streamId);
        assertEq(sender, address(launchpad), "Sender should be launchpad");

        bool isCancelable = sablierLockup.isCancelable(streamId);
        assertTrue(isCancelable, "Stream should be cancelable");

        bool isTransferable = sablierLockup.isTransferable(streamId);
        assertTrue(isTransferable, "Stream should be transferable");

        // Test vesting after 6 months
        vm.warp(block.timestamp + 183 days);

        uint256 withdrawable = sablierLockup.withdrawableAmountOf(streamId);
        assertGt(withdrawable, 0, "Should have withdrawable amount");

        // Approximately 50% should be vested (6/12 months)
        uint256 expectedMin = lockAmount * 48 / 100; // 48%
        uint256 expectedMax = lockAmount * 52 / 100; // 52%
        assertGe(withdrawable, expectedMin, "Should have at least 48% vested");
        assertLe(withdrawable, expectedMax, "Should have at most 52% vested");

        // Test withdrawal
        vm.prank(recipient);
        sablierLockup.withdraw(streamId, recipient, uint128(withdrawable));

        uint256 balance = IERC20(latestAsset).balanceOf(recipient);
        assertEq(balance, withdrawable, "Should receive withdrawn amount");
    }

    function test_CreatorAllocation_MultipleRecipients_VerifySablier() public {
        address founder = makeAddr("founder");
        address advisor = makeAddr("advisor");
        address treasury = makeAddr("treasury");

        NumeraireCreatorAllocation[] memory locks = new NumeraireCreatorAllocation[](3);
        locks[0] = NumeraireCreatorAllocation({
            recipient: founder,
            amount: 27_000_000_000e18, // 27B tokens
            lockStartTimestamp: uint40(block.timestamp + 30 days),
            lockEndTimestamp: uint40(block.timestamp + 730 days)
        });
        locks[1] = NumeraireCreatorAllocation({
            recipient: advisor,
            amount: 13_500_000_000e18, // 13.5B tokens
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });
        locks[2] = NumeraireCreatorAllocation({
            recipient: treasury,
            amount: 4_500_000_000e18, // 4.5B tokens
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 180 days)
        });

        BundleParams memory params = _createBundleParams(locks);
        
        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify 3 streams created
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(nextStreamIdAfter, nextStreamIdBefore + 3, "Should create 3 streams");

        // Verify each stream
        for (uint256 i = 0; i < 3; i++) {
            uint256 streamId = nextStreamIdBefore + i;

            address streamRecipient = sablierLockup.getRecipient(streamId);
            assertEq(streamRecipient, locks[i].recipient, "Recipient mismatch");

            uint256 depositedAmount = sablierLockup.getDepositedAmount(streamId);
            assertEq(depositedAmount, locks[i].amount, "Amount mismatch");

            address sender = sablierLockup.getSender(streamId);
            assertEq(sender, address(launchpad), "Sender should be launchpad");
        }

        // Test different vesting schedules
        vm.warp(block.timestamp + 90 days);

        uint256 stream0 = nextStreamIdBefore;
        uint256 stream1 = nextStreamIdBefore + 1;
        uint256 stream2 = nextStreamIdBefore + 2;

        uint256 withdrawable0 = sablierLockup.withdrawableAmountOf(stream0);
        uint256 withdrawable1 = sablierLockup.withdrawableAmountOf(stream1);
        uint256 withdrawable2 = sablierLockup.withdrawableAmountOf(stream2);

        // Founder should have some vested (90 days - 30 day cliff = 60 days vested / 730 days total)
        assertGt(withdrawable0, 0, "Founder should have tokens vested");

        // Advisor should have ~25% vested (90/365 days)
        assertGt(withdrawable1, locks[1].amount * 20 / 100, "Advisor should have >20% vested");

        // Treasury should have ~50% vested (90/180 days)
        assertGt(withdrawable2, locks[2].amount * 45 / 100, "Treasury should have >45% vested");
    }

    function test_CreatorAllocation_LinearVesting() public {
        address recipient = makeAddr("recipient");
        uint256 lockAmount = 36_500_000_000e18; // 36.5B tokens

        uint256 startTime = block.timestamp;

        NumeraireCreatorAllocation[] memory locks = new NumeraireCreatorAllocation[](1);
        locks[0] = NumeraireCreatorAllocation({
            recipient: recipient,
            amount: lockAmount,
            lockStartTimestamp: uint40(startTime),
            lockEndTimestamp: uint40(startTime + 365 days)
        });

        BundleParams memory params = _createBundleParams(locks);
        
        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);

        uint256 streamId = nextStreamIdBefore;

        // Test linear vesting at different points

        // 25% through (91 days from start)
        vm.warp(startTime + 91 days);
        uint256 withdrawable25 = sablierLockup.withdrawableAmountOf(streamId);

        // 50% through (182 days from start)
        vm.warp(startTime + 182 days);
        uint256 withdrawable50 = sablierLockup.withdrawableAmountOf(streamId);

        // 75% through (273 days from start)
        vm.warp(startTime + 273 days);
        uint256 withdrawable75 = sablierLockup.withdrawableAmountOf(streamId);

        // 100% through (365+ days from start)
        vm.warp(startTime + 366 days);
        uint256 withdrawable100 = sablierLockup.withdrawableAmountOf(streamId);

        // Verify linear progression
        assertLt(withdrawable25, withdrawable50, "Vesting should increase from 25% to 50%");
        assertLt(withdrawable50, withdrawable75, "Vesting should increase from 50% to 75%");

        // At 100%, should be able to withdraw full amount
        assertEq(withdrawable75, lockAmount, "Should be fully vested at 75%");
        assertEq(withdrawable100, lockAmount, "Should remain fully vested at 100%");
    }

    function test_CreatorAllocation_ZeroAmountSkipped() public {
        NumeraireCreatorAllocation[] memory locks = new NumeraireCreatorAllocation[](3);
        locks[0] = NumeraireCreatorAllocation({
            recipient: makeAddr("recipient1"),
            amount: 20_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp + 1 days),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });
        locks[1] = NumeraireCreatorAllocation({
            recipient: makeAddr("recipient2"),
            amount: 0, // Zero amount
            lockStartTimestamp: uint40(block.timestamp + 1 days),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });
        locks[2] = NumeraireCreatorAllocation({
            recipient: makeAddr("recipient3"),
            amount: 10_000_000_000e18,
            lockStartTimestamp: uint40(block.timestamp + 1 days),
            lockEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleParams memory params = _createBundleParams(locks);
        
        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorAllocations(params);

        // Should create only 2 streams (skip zero amount)
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(nextStreamIdAfter, nextStreamIdBefore + 2, "Should create only 2 streams");
    }

    function test_CreatorAllocation_100Recipients() public {
        // Create 100 creator locks
        NumeraireCreatorAllocation[] memory locks = new NumeraireCreatorAllocation[](100);
        uint256 totalLocked = 0;

        // Total supply is 100B, allocate ~45B to creator locks (45%)
        // 450M tokens per creator on average = 100 * 450M = 45B
        for (uint256 i = 0; i < 100; i++) {
            address recipient = makeAddr(string(abi.encodePacked("creator", i)));
            uint256 amount = (i + 1) * 10_000_000e18; // 10M, 20M, 30M, ..., 1B tokens (total: 50.5B)

            // Scale down to fit in 45B total
            amount = amount * 45 / 51; // Reduces to ~44.1B total

            locks[i] = NumeraireCreatorAllocation({
                recipient: recipient,
                amount: amount,
                lockStartTimestamp: uint40(block.timestamp + (i % 10) * 1 days), // Varying cliff periods
                lockEndTimestamp: uint40(block.timestamp + 365 days + (i % 5) * 30 days) // Varying vesting durations
             });

            totalLocked += amount;
        }

        BundleParams memory params = _createBundleParams(locks);
        
        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify 100 streams created
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(nextStreamIdAfter, nextStreamIdBefore + 100, "Should create 100 streams");

        // Verify each stream
        for (uint256 i = 0; i < 100; i++) {
            uint256 streamId = nextStreamIdBefore + i;

            address streamRecipient = sablierLockup.getRecipient(streamId);
            assertEq(streamRecipient, locks[i].recipient, "Recipient mismatch");

            uint256 depositedAmount = sablierLockup.getDepositedAmount(streamId);
            assertEq(depositedAmount, locks[i].amount, "Amount mismatch");

            address sender = sablierLockup.getSender(streamId);
            assertEq(sender, address(launchpad), "Sender should be launchpad");

            bool isCancelable = sablierLockup.isCancelable(streamId);
            assertTrue(isCancelable, "Stream should be cancelable");
        }

        // Test withdrawals after 6 months
        vm.warp(block.timestamp + 183 days);

        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < 100; i++) {
            uint256 streamId = nextStreamIdBefore + i;
            address recipient = locks[i].recipient;

            uint256 withdrawable = sablierLockup.withdrawableAmountOf(streamId);

            if (withdrawable > 0) {
                vm.prank(recipient);
                sablierLockup.withdraw(streamId, recipient, uint128(withdrawable));

                uint256 balance = IERC20(latestAsset).balanceOf(recipient);
                assertEq(balance, withdrawable, "Should receive withdrawn amount");

                totalWithdrawn += withdrawable;
            }
        }
    }
}
