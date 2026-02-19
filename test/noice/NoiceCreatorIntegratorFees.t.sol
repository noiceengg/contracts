// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import { BundleWithVestingParams, NoiceCreatorAllocation, NoicePrebuyParticipant } from "src/NoiceLaunchpad.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

contract NoiceCreatorIntegratorFeesTest is NoiceBaseTest {
    address public creator = makeAddr("creator");
    address public attacker = makeAddr("attacker");
    address public feeRecipient = makeAddr("feeRecipient");

    function test_CreatorIsIntegratorAndCanCollectIntegratorFees() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(creator);
        launchpad.bundleWithCreatorVesting(params, participants);

        address asset = _computeAssetAddress(params.createData.salt);
        (,,,,,,,,, address integrator) = airlock.getAssetData(asset);
        assertEq(integrator, creator, "Integrator should be creator");

        // Simulate accrued integrator fees and available token balance on Airlock.
        uint256 feeAmount = 10e18;
        deal(NOICE_TOKEN, address(airlock), feeAmount);

        bytes32 integratorOuterSlot = keccak256(abi.encode(creator, uint256(4)));
        bytes32 integratorFeeSlot = keccak256(abi.encode(NOICE_TOKEN, integratorOuterSlot));
        vm.store(address(airlock), integratorFeeSlot, bytes32(feeAmount));

        vm.prank(creator);
        airlock.collectIntegratorFees(feeRecipient, NOICE_TOKEN, feeAmount);
        assertEq(IERC20(NOICE_TOKEN).balanceOf(feeRecipient), feeAmount, "Creator should collect integrator fees");

        vm.prank(attacker);
        vm.expectRevert();
        airlock.collectIntegratorFees(attacker, NOICE_TOKEN, 1);
    }
}
