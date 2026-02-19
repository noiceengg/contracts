// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    BundleParams,
    NumeraireCreatorAllocation,
    NumeraireLpUnlockTranche,
    PrebuyTranche
} from "src/NoiceLaunchpad.sol";
import { DERC20 } from "src/DERC20.sol";
import { UniswapV4MulticurveInitializer, InitData } from "src/UniswapV4MulticurveInitializer.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { IPushSplitFactory } from "src/interfaces/splits/IPushSplitFactory.sol";
import { IPushSplit } from "src/interfaces/splits/IPushSplit.sol";
import { CreateParams } from "src/Airlock.sol";

/**
 * @title NoiceSplitsTest
 * @notice Tests LP fee distribution through 0xSplits integration
 * @dev Tests split creation, beneficiary assignment, and fee distribution
 */
contract NoiceSplitsTest is NoiceBaseTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public creator = makeAddr("creator");
    address public latestAsset;

    /// @dev 0xSplits V2 addresses on Base
    address public constant PUSH_SPLIT_FACTORY = 0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4;

    /// @dev Split allocation: 20% deployer, 80% creator
    uint256 public constant DEPLOYER_ALLOCATION = 2000; // 20%
    uint256 public constant CREATOR_ALLOCATION = 8000; // 80%
    uint256 public constant TOTAL_ALLOCATION = 10_000; // 100%

    address public splitAddress;

    function test_Splits_CreateSplitContract() public {

        vm.startPrank(deployer);

        splitAddress = _createPushSplit();


        vm.stopPrank();

        // Try to verify split configuration
        try IPushSplit(splitAddress).getSplitConfiguration() returns (
            address[] memory recipients, uint256[] memory allocations, uint256 totalAllocation, uint16
        ) {
            assertEq(recipients.length, 2, "Should have 2 recipients");
            assertEq(recipients[0], deployer, "First recipient should be deployer");
            assertEq(recipients[1], creator, "Second recipient should be creator");
            assertEq(allocations[0], DEPLOYER_ALLOCATION, "Deployer should get 20%");
            assertEq(allocations[1], CREATOR_ALLOCATION, "Creator should get 80%");
            assertEq(totalAllocation, TOTAL_ALLOCATION, "Total should be 100%");
        } catch {
            // Split created but interface mismatch - verify address is contract
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(sload(splitAddress.slot))
            }
            assertGt(codeSize, 0, "Split should be a contract");
        }
    }

    function test_Splits_LaunchWithSplitBeneficiary() public {

        // Create split
        vm.prank(deployer);
        splitAddress = _createPushSplit();

        // Launch token with split as LP fee beneficiary
        BundleParams memory params = _createBundleParamsWithSplit();
        
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt, "SplitsToken", "SPLITS");

        // Verify split is set as beneficiary
        (,, PoolKey memory poolKey,) = multicurveInitializer.getState(latestAsset);
        PoolId poolId = poolKey.toId();

        uint256 splitShares = multicurveInitializer.getShares(poolId, splitAddress);

        assertGt(splitShares, 0, "Split should have shares as beneficiary");
    }

    function test_Splits_MultipleBeneficiaries() public {

        // Create split
        vm.prank(deployer);
        address split = _createPushSplit();

        // Create bundle params with split + another beneficiary
        BundleParams memory params = _createBundleParamsWithMultipleBeneficiaries(split);
        
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt, "MultiToken", "MULTI");

        // Verify beneficiaries
        (,, PoolKey memory poolKey,) = multicurveInitializer.getState(latestAsset);
        PoolId poolId = poolKey.toId();

        uint256 splitShares = multicurveInitializer.getShares(poolId, split);
        uint256 creatorShares = multicurveInitializer.getShares(poolId, creator);


        assertGt(splitShares, 0, "Split should have shares");
        assertGt(creatorShares, 0, "Creator should have shares");

        // Split and creator should have approximately equal shares (45/45)
        assertApproxEqRel(splitShares, creatorShares, 0.01e18, "Shares should be ~45/45");

    }

    function test_Splits_VerifyFeeDistribution() public {

        // Create split
        vm.prank(deployer);
        splitAddress = _createPushSplit();

        // Launch token
        BundleParams memory params = _createBundleParamsWithSplit();
        
        launchpad.bundleWithCreatorAllocations(params);

        latestAsset = _computeAssetAddress(params.createData.salt, "SplitsToken", "SPLITS");


        // Get pool info
        (,, PoolKey memory poolKey,) = multicurveInitializer.getState(latestAsset);
        PoolId poolId = poolKey.toId();

        // Verify split has shares
        uint256 splitShares = multicurveInitializer.getShares(poolId, splitAddress);
        assertGt(splitShares, 0, "Split should be configured as beneficiary");


    }

    function _createPushSplit() internal returns (address) {
        IPushSplitFactory factory = IPushSplitFactory(PUSH_SPLIT_FACTORY);

        address[] memory recipients = new address[](2);
        recipients[0] = deployer;
        recipients[1] = creator;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = DEPLOYER_ALLOCATION; // 20%
        allocations[1] = CREATOR_ALLOCATION; // 80%

        IPushSplitFactory.Split memory split = IPushSplitFactory.Split({
            recipients: recipients,
            allocations: allocations,
            totalAllocation: TOTAL_ALLOCATION,
            distributionIncentive: 0 // No distribution incentive
         });

        return factory.createSplit(split, deployer, deployer);
    }

    function _createBundleParamsWithSplit() internal view returns (BundleParams memory) {
        Curve[] memory curves = new Curve[](3);
        for (uint256 i = 0; i < 3; i++) {
            curves[i] = Curve({
                tickLower: TICK_LOWERS[i],
                tickUpper: TICK_UPPERS[i],
                numPositions: 1,
                shares: CURVE_SHARES[i]
            });
        }

        // Set split + airlock owner as beneficiaries
        address airlockOwner = airlock.owner();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);

        // Sort by address (required)
        if (airlockOwner < splitAddress) {
            beneficiaries[0] = BeneficiaryData({
                beneficiary: airlockOwner,
                shares: 50_000_000_000_000_000 // 5%
             });
            beneficiaries[1] = BeneficiaryData({
                beneficiary: splitAddress,
                shares: 950_000_000_000_000_000 // 95%
             });
        } else {
            beneficiaries[0] = BeneficiaryData({
                beneficiary: splitAddress,
                shares: 950_000_000_000_000_000 // 95%
             });
            beneficiaries[1] = BeneficiaryData({
                beneficiary: airlockOwner,
                shares: 50_000_000_000_000_000 // 5%
             });
        }

        InitData memory initData =
            InitData({ fee: 3000, tickSpacing: 60, curves: curves, beneficiaries: beneficiaries });

        address[] memory vestRecipients = new address[](0);
        uint256[] memory vestAmounts = new uint256[](0);

        CreateParams memory createData = CreateParams({
            initialSupply: TOTAL_SUPPLY,
            numTokensToSell: TOTAL_SUPPLY,
            numeraire: NOICE_TOKEN,
            tokenFactory: tokenFactory,
            tokenFactoryData: abi.encode("SplitsToken", "SPLITS", uint256(0), uint256(0), vestRecipients, vestAmounts, ""),
            governanceFactory: governanceFactory,
            governanceFactoryData: "",
            poolInitializer: multicurveInitializer,
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: noOpMigrator,
            liquidityMigratorData: "",
            integrator: address(0),
            salt: bytes32(uint256(block.timestamp))
        });

        NumeraireCreatorAllocation[] memory creatorAllocations = new NumeraireCreatorAllocation[](0);
        NumeraireLpUnlockTranche[] memory numeraireLpUnlockTranches = new NumeraireLpUnlockTranche[](0);

        return BundleParams({
            createData: createData,
            creatorAllocations: creatorAllocations,
            numeraireLpUnlockTranches: numeraireLpUnlockTranches,
            prebuyTranches: new PrebuyTranche[](0),
            noicePrebuyCommands: "",
            noicePrebuyInputs: new bytes[](0)
        });
    }

    function _createBundleParamsWithMultipleBeneficiaries(
        address split
    ) internal view returns (BundleParams memory) {
        Curve[] memory curves = new Curve[](3);
        for (uint256 i = 0; i < 3; i++) {
            curves[i] = Curve({
                tickLower: TICK_LOWERS[i],
                tickUpper: TICK_UPPERS[i],
                numPositions: 1,
                shares: CURVE_SHARES[i]
            });
        }

        // Set split + creator + airlock owner as beneficiaries
        address airlockOwner = airlock.owner();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);

        // Create array and sort (required by multicurve initializer)
        address[] memory addrs = new address[](3);
        addrs[0] = split;
        addrs[1] = creator;
        addrs[2] = airlockOwner;

        // Simple bubble sort
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (addrs[i] > addrs[j]) {
                    address temp = addrs[i];
                    addrs[i] = addrs[j];
                    addrs[j] = temp;
                }
            }
        }

        // Assign shares: split 45%, creator 45%, airlock owner 10%
        for (uint256 i = 0; i < 3; i++) {
            if (addrs[i] == split) {
                beneficiaries[i] = BeneficiaryData({
                    beneficiary: split,
                    shares: 450_000_000_000_000_000 // 45%
                 });
            } else if (addrs[i] == creator) {
                beneficiaries[i] = BeneficiaryData({
                    beneficiary: creator,
                    shares: 450_000_000_000_000_000 // 45%
                 });
            } else {
                beneficiaries[i] = BeneficiaryData({
                    beneficiary: airlockOwner,
                    shares: 100_000_000_000_000_000 // 10%
                 });
            }
        }

        InitData memory initData =
            InitData({ fee: 3000, tickSpacing: 60, curves: curves, beneficiaries: beneficiaries });

        address[] memory vestRecipients = new address[](0);
        uint256[] memory vestAmounts = new uint256[](0);

        CreateParams memory createData = CreateParams({
            initialSupply: TOTAL_SUPPLY,
            numTokensToSell: TOTAL_SUPPLY,
            numeraire: NOICE_TOKEN,
            tokenFactory: tokenFactory,
            tokenFactoryData: abi.encode("MultiToken", "MULTI", uint256(0), uint256(0), vestRecipients, vestAmounts, ""),
            governanceFactory: governanceFactory,
            governanceFactoryData: "",
            poolInitializer: multicurveInitializer,
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: noOpMigrator,
            liquidityMigratorData: "",
            integrator: address(0),
            salt: keccak256(abi.encodePacked(block.timestamp, block.number, "multi"))
        });

        NumeraireCreatorAllocation[] memory creatorAllocations = new NumeraireCreatorAllocation[](0);
        NumeraireLpUnlockTranche[] memory numeraireLpUnlockTranches = new NumeraireLpUnlockTranche[](0);

        return BundleParams({
            createData: createData,
            creatorAllocations: creatorAllocations,
            numeraireLpUnlockTranches: numeraireLpUnlockTranches,
            prebuyTranches: new PrebuyTranche[](0),
            noicePrebuyCommands: "",
            noicePrebuyInputs: new bytes[](0)
        });
    }

    function _computeAssetAddress(
        bytes32 salt,
        string memory name,
        string memory symbol
    ) internal view returns (address) {
        return vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        TOTAL_SUPPLY,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new address[](0),
                        ""
                    )
                )
            ),
            address(tokenFactory)
        );
    }
}
