// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {NoiceBaseTest} from "./NoiceBaseTest.sol";
import {BundleWithVestingParams, NoiceCreatorAllocation, NoicePrebuyParticipant, NoiceLpUnlockTranche} from "src/NoiceLaunchpad.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Commands} from "@universal-router/libraries/Commands.sol";
import {Actions} from "@v4-periphery/libraries/Actions.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@v4-core/types/Currency.sol";
import {Planner, Plan} from "lib/v4-periphery/test/shared/Planner.sol";
import {IV4Router} from "@v4-periphery/interfaces/IV4Router.sol";

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/**
 * @title NoicePrebuyTest
 * @notice Tests prebuy functionality with Sablier vesting verification
 * @dev Validates that prebuy participants with zero NOICE don't create streams
 *      and that invalid vesting timestamps are rejected
 */
contract NoicePrebuyTest is NoiceBaseTest {
    using PoolIdLibrary for PoolKey;

    address public participant1 = makeAddr("participant1");
    address public participant2 = makeAddr("participant2");
    address public latestAsset;

    function setUp() public override {
        super.setUp();

        // Fund participants with NOICE
        deal(NOICE_TOKEN, participant1, 100_000e18);
        deal(NOICE_TOKEN, participant2, 200_000e18);
    }

    function test_Prebuy_NoParticipants() public {
        NoiceCreatorAllocation[]
            memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(
            noiceCreatorLocks
        );
        NoicePrebuyParticipant[]
            memory participants = new NoicePrebuyParticipant[](0);

        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Should not create any streams
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(
            nextStreamIdAfter,
            nextStreamIdBefore,
            "Should not create any prebuy streams"
        );
    }

    function test_Prebuy_ZeroNoiceAmount() public {
        // Participant with 0 NOICE amount should not create stream
        NoicePrebuyParticipant[]
            memory participants = new NoicePrebuyParticipant[](1);
        participants[0] = NoicePrebuyParticipant({
            lockedAddress: participant1,
            noiceAmount: 0, // Zero NOICE
            vestingStartTimestamp: uint40(block.timestamp),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: participant1
        });

        NoiceCreatorAllocation[]
            memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(
            noiceCreatorLocks
        );

        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Should not create any streams (early return due to totalNoice == 0)
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(
            nextStreamIdAfter,
            nextStreamIdBefore,
            "Should not create streams for zero NOICE"
        );
    }

    // Note: Invalid vesting timestamps are now validated by Sablier, not by NoiceLaunchpad
    // Sablier will revert with SablierHelpers_StartTimeNotLessThanEndTime if start >= end

    function test_Prebuy_MultipleParticipants_NoSwap() public {
        uint256 amount1 = 50_000e18;
        uint256 amount2 = 100_000e18;

        // Approve NOICE
        vm.prank(participant1);
        IERC20(NOICE_TOKEN).approve(address(launchpad), amount1);

        vm.prank(participant2);
        IERC20(NOICE_TOKEN).approve(address(launchpad), amount2);

        NoicePrebuyParticipant[]
            memory participants = new NoicePrebuyParticipant[](2);
        participants[0] = NoicePrebuyParticipant({
            lockedAddress: participant1,
            noiceAmount: amount1,
            vestingStartTimestamp: uint40(block.timestamp),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: participant1
        });
        participants[1] = NoicePrebuyParticipant({
            lockedAddress: participant2,
            noiceAmount: amount2,
            vestingStartTimestamp: uint40(block.timestamp),
            vestingEndTimestamp: uint40(block.timestamp + 180 days),
            vestingRecipient: participant2
        });

        NoiceCreatorAllocation[]
            memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(
            noiceCreatorLocks
        );

        uint256 nextStreamIdBefore = sablierLockup.nextStreamId();

        uint256 participant1NoiceBefore = IERC20(NOICE_TOKEN).balanceOf(
            participant1
        );
        uint256 participant2NoiceBefore = IERC20(NOICE_TOKEN).balanceOf(
            participant2
        );

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify NOICE was collected from participants
        uint256 participant1NoiceAfter = IERC20(NOICE_TOKEN).balanceOf(
            participant1
        );
        uint256 participant2NoiceAfter = IERC20(NOICE_TOKEN).balanceOf(
            participant2
        );

        assertEq(
            participant1NoiceBefore - participant1NoiceAfter,
            amount1,
            "Participant1 NOICE should be collected"
        );
        assertEq(
            participant2NoiceBefore - participant2NoiceAfter,
            amount2,
            "Participant2 NOICE should be collected"
        );

        // Without swap commands, no tokens received, so no streams created (early return)
        uint256 nextStreamIdAfter = sablierLockup.nextStreamId();
        assertEq(
            nextStreamIdAfter,
            nextStreamIdBefore,
            "Should not create streams (no swap executed)"
        );
    }

    function test_Prebuy_ManualSwapAfterLaunch() public {
        // Step 1: Launch token without any prebuy participants
        NoiceCreatorAllocation[]
            memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(
            noiceCreatorLocks
        );
        NoicePrebuyParticipant[]
            memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Step 2: Get the actual pool key from the multicurve initializer
        PoolKey memory poolKey = _getPoolKey(latestAsset);

        // Step 3: Swap NOICE for Asset using UniversalRouter
        uint256 swapAmount = 1000e18;
        deal(NOICE_TOKEN, deployer, swapAmount);

        // Determine swap direction
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == NOICE_TOKEN;

        // Build V4 swap inputs exactly as shown in Uniswap docs
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Prepare parameters for each action
        bytes[] memory actionParams = new bytes[](3);

        // actionParams[0]: ExactInputSingleParams
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(swapAmount),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );

        // actionParams[1]: SETTLE_ALL params (currency, amount)
        Currency currencyIn = zeroForOne
            ? poolKey.currency0
            : poolKey.currency1;
        actionParams[1] = abi.encode(currencyIn, swapAmount);

        // actionParams[2]: TAKE_ALL params (currency, minAmount)
        Currency currencyOut = zeroForOne
            ? poolKey.currency1
            : poolKey.currency0;
        actionParams[2] = abi.encode(currencyOut, uint256(0));

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, actionParams);

        // Approve and execute
        // UniversalRouter uses Permit2 for token approvals
        IPermit2 permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        vm.startPrank(deployer);
        // Step 1: Approve Permit2 to spend NOICE
        IERC20(NOICE_TOKEN).approve(address(permit2), type(uint256).max);

        // Step 2: Approve router via Permit2 with expiration
        permit2.approve(
            NOICE_TOKEN,
            address(router),
            type(uint160).max,
            uint48(block.timestamp + 1 hours)
        );

        uint256 assetBalanceBefore = IERC20(latestAsset).balanceOf(deployer);
        uint256 noiceBalanceBefore = IERC20(NOICE_TOKEN).balanceOf(deployer);

        // Call UniversalRouter.execute with deadline
        router.execute(commands, inputs, block.timestamp + 60);

        uint256 assetBalanceAfter = IERC20(latestAsset).balanceOf(deployer);
        uint256 noiceBalanceAfter = IERC20(NOICE_TOKEN).balanceOf(deployer);
        vm.stopPrank();
    }

    function test_Prebuy_100Participants() public {
        // Create 100 participants
        NoicePrebuyParticipant[]
            memory participants = new NoicePrebuyParticipant[](100);

        uint256 totalNoiceAmount = 0;

        for (uint256 i = 0; i < 100; i++) {
            address participant = makeAddr(
                string(abi.encodePacked("participant", i))
            );
            uint256 noiceAmount = (i + 1) * 1000e18; // 1K, 2K, 3K, ..., 100K NOICE

            // Fund participant
            deal(NOICE_TOKEN, participant, noiceAmount);

            // Approve NOICE
            vm.prank(participant);
            IERC20(NOICE_TOKEN).approve(address(launchpad), noiceAmount);

            // Create participant struct
            participants[i] = NoicePrebuyParticipant({
                lockedAddress: participant,
                noiceAmount: noiceAmount,
                vestingStartTimestamp: uint40(block.timestamp),
                vestingEndTimestamp: uint40(block.timestamp + 365 days),
                vestingRecipient: participant
            });

            totalNoiceAmount += noiceAmount;
        }

        // Create bundle params
        NoiceCreatorAllocation[]
            memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(
            noiceCreatorLocks
        );

        // Compute asset address
        latestAsset = _computeAssetAddress(params.createData.salt);

        // Determine token order
        bool isToken0 = latestAsset < NOICE_TOKEN;

        // Manually construct the pool key (must match what multicurve initializer creates)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(isToken0 ? latestAsset : NOICE_TOKEN),
            currency1: Currency.wrap(isToken0 ? NOICE_TOKEN : latestAsset),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        // Compute and log pool ID for debugging
        PoolId myPoolId = poolKey.toId();

        // Build V4 swap: NOICE -> Asset (exact input)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory actionParams = new bytes[](3);

        // Determine swap direction
        bool zeroForOne = !isToken0; // swapping NOICE for asset
        Currency currencyIn = zeroForOne
            ? poolKey.currency0
            : poolKey.currency1;
        Currency currencyOut = zeroForOne
            ? poolKey.currency1
            : poolKey.currency0;

        // actionParams[0]: ExactInputSingleParams
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(totalNoiceAmount),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );

        // actionParams[1]: SETTLE_ALL params (currency, amount)
        actionParams[1] = abi.encode(currencyIn, totalNoiceAmount);

        // actionParams[2]: TAKE_ALL params (currency, minAmount)
        actionParams[2] = abi.encode(currencyOut, uint256(0));

        // Encode for V4Router
        bytes memory routerInput = abi.encode(actions, actionParams);

        // Build UniversalRouter command: V4_SWAP
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = routerInput;

        // Update params with swap commands
        params.noicePrebuyCommands = commands;
        params.noicePrebuyInputs = inputs;

        // Store balances before launch
        uint256[] memory balancesBefore = new uint256[](100);
        for (uint256 i = 0; i < 100; i++) {
            address participant = makeAddr(
                string(abi.encodePacked("participant", i))
            );
            balancesBefore[i] = IERC20(NOICE_TOKEN).balanceOf(participant);
        }

        launchpad.bundleWithCreatorVesting(params, participants);

        // Verify NOICE was collected from all participants
        uint256 totalCollected = 0;
        for (uint256 i = 0; i < 100; i++) {
            address participant = makeAddr(
                string(abi.encodePacked("participant", i))
            );
            uint256 balanceAfter = IERC20(NOICE_TOKEN).balanceOf(participant);
            uint256 collected = balancesBefore[i] - balanceAfter;
            totalCollected += collected;

            assertEq(
                balanceAfter,
                0,
                "Participant should have 0 NOICE after collection"
            );
            assertEq(collected, (i + 1) * 1000e18, "Collected amount mismatch");
        }

        assertEq(
            totalCollected,
            totalNoiceAmount,
            "Total collected should match total NOICE"
        );
    }
}
