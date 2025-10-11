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
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Position } from "src/types/Position.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TestMulticurveHook } from "./mocks/TestMulticurveHook.sol";

/**
 * @title NoiceLpUnlockTest
 * @notice Tests LP unlock functionality
 * @dev Validates position creation, recipient tracking, and withdrawal mechanism
 */
contract NoiceLpUnlockTest is NoiceBaseTest {
    address public recipient1 = makeAddr("recipient1");
    address public recipient2 = makeAddr("recipient2");
    address public recipient3 = makeAddr("recipient3");
    address public latestAsset;

    // Override setUp to use TestMulticurveHook for valid tranche tests
    bool public useTestHook = false;

    function setUp() public override virtual {
        if (!useTestHook) {
            // Use default setup from NoiceBaseTest
            super.setUp();
        } else {
            // Use TestMulticurveHook setup (like NoiceLpUnlockIntegration)
            _setUpWithTestHook();
        }
    }

    function _setUpWithTestHook() internal {
        // Fork Base mainnet
        string memory rpcUrl = vm.envString("BASE_MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Initialize external contracts
        airlock = Airlock(payable(AIRLOCK));
        router = UniversalRouter(payable(UNIVERSAL_ROUTER));
        sablierLockup = ISablierLockup(SABLIER_LOCKUP);
        sablierBatchLockup = ISablierBatchLockup(SABLIER_BATCH_LOCKUP);
        poolManager = IPoolManager(POOL_MANAGER);

        // Deploy test contracts
        governanceFactory = new TeamGovernanceFactory();
        tokenFactory = new TokenFactory(address(airlock));
        noOpMigrator = new NoOpMigrator(address(airlock));

        // Calculate hook address with correct permissions first
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );

        // Deploy multicurve initializer first (with reference to hook address)
        multicurveInitializer = new UniswapV4MulticurveInitializer(
            address(airlock), poolManager, UniswapV4MulticurveInitializerHook(hookAddress)
        );

        // Deploy launchpad
        launchpad = new NoiceLaunchpad(airlock, router, sablierLockup, sablierBatchLockup, poolManager, address(this));

        // Deploy custom hook that whitelists both initializer AND launchpad
        deployCodeTo(
            "TestMulticurveHook",
            abi.encode(poolManager, address(multicurveInitializer), address(launchpad)),
            hookAddress
        );

        hook = UniswapV4MulticurveInitializerHook(hookAddress);

        // Register modules with Airlock
        _registerAirlockModules();
    }

    function test_LpUnlock_NoTranches() public {

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, new NoiceLpUnlockTranche[](0));
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Verify no positions created
        uint256 positionCount = launchpad.getNoiceLpUnlockPositionCount(latestAsset);
        assertEq(positionCount, 0, "Should have 0 LP unlock positions");

    }

    function test_LpUnlock_PercentageCalculation() public {

        uint256 unlockPercentage = 1000; // 10%
        uint256 expectedAmount = TOTAL_SUPPLY * unlockPercentage / 10_000; // 10B tokens


        assertEq(expectedAmount, 10_000_000_000e18, "Should be 10B tokens");

    }

    function test_LpUnlock_TrancheAllocation() public {

        uint256 unlockPercentage = 1500; // 15%
        uint256 totalUnlockAmount = TOTAL_SUPPLY * unlockPercentage / 10_000; // 15B tokens

        // Distribute across 3 tranches: 40%, 35%, 25%
        uint256 tranche1 = totalUnlockAmount * 40 / 100; // 6B
        uint256 tranche2 = totalUnlockAmount * 35 / 100; // 5.25B
        uint256 tranche3 = totalUnlockAmount * 25 / 100; // 3.75B


        uint256 totalAllocated = tranche1 + tranche2 + tranche3;
        assertEq(totalAllocated, totalUnlockAmount, "Tranches should sum to total");

    }

    function test_LpUnlock_InvalidTickRange() public {

        uint256 unlockPercentage = 1000; // 10%
        uint256 expectedAmount = TOTAL_SUPPLY * unlockPercentage / 10_000;

        // Invalid: tickLower >= tickUpper
        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] = NoiceLpUnlockTranche({
            amount: expectedAmount,
            tickLower: 30_000,
            tickUpper: 20_000, // Invalid: upper < lower
            recipient: recipient1
        });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.expectRevert(abi.encodeWithSignature("InvalidNoiceLpUnlockTranches()"));
        launchpad.bundleWithCreatorVesting(params, participants);

    }

    function test_LpUnlock_ExceedsTotalSupply() public {

        // Create LP unlock that exceeds total supply
        // Will revert with arithmetic underflow (Solidity 0.8+ panic)
        NoiceLpUnlockTranche[] memory tranches = new NoiceLpUnlockTranche[](1);
        tranches[0] = NoiceLpUnlockTranche({
            amount: TOTAL_SUPPLY + 1, // Exceeds total supply
            tickLower: 20_100,
            tickUpper: 30_000,
            recipient: recipient1
        });

        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks, tranches);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.expectRevert();
        launchpad.bundleWithCreatorVesting(params, participants);

    }
}

/**
 * @title NoiceLpUnlockValidTranchesTest
 * @notice Tests LP unlock with valid tranches using TestMulticurveHook
 * @dev Uses custom hook that allows launchpad to add liquidity
 */
contract NoiceLpUnlockValidTranchesTest is NoiceLpUnlockTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function setUp() public override virtual {
        // Enable test hook for this contract
        useTestHook = true;
        super.setUp();
    }

    function test_LpUnlock_ValidTranches_SingleTranche() public {

        uint256 unlockPercentage = 1000; // 10%
        uint256 tokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000; // 10B tokens

        // Define tick range - positions BELOW current tick (asset is token1, tick ~20040)
        int24 tickLower = 10_020; // Multiple of 60
        int24 tickUpper = 19_980; // Multiple of 60, below current tick


        // Create valid tranches
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
        assertGt(positions[0].liquidity, 0, "Liquidity should be non-zero");

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

    function test_LpUnlock_ValidTranches_MultipleTranches() public {

        uint256 unlockPercentage = 1500; // 15%
        uint256 totalTokenAmount = TOTAL_SUPPLY * unlockPercentage / 10_000; // 15B tokens

        // Define tick ranges - all BELOW current tick
        int24[3] memory tickLowers = [int24(15_000), int24(10_020), int24(5040)];
        int24[3] memory tickUppers = [int24(18_000), int24(13_980), int24(9000)];
        address[3] memory recipients = [recipient1, recipient2, recipient3];
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

    function test_LpUnlock_ValidTranches_WithdrawalFlow() public {

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
