// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import { BundleWithVestingParams, NoiceCreatorAllocation, NoicePrebuyParticipant } from "src/NoiceLaunchpad.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title NoiceSweepTest
 * @notice Tests sweep functionality for recovering tokens from launchpad
 */
contract NoiceSweepTest is NoiceBaseTest {
    address public recipient = makeAddr("recipient");
    address public attacker = makeAddr("attacker");
    address public latestAsset;

    function test_Sweep_TokensToRecipient() public {

        // Launch token to get some dust
        NoiceCreatorAllocation[] memory locks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(locks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Check launchpad has some dust
        uint256 dustAmount = IERC20(latestAsset).balanceOf(address(launchpad));
        assertGt(dustAmount, 0, "Should have dust");

        // Owner sweeps to recipient
        launchpad.sweep(latestAsset, recipient);

        // Verify recipient got the dust
        uint256 recipientBalance = IERC20(latestAsset).balanceOf(recipient);
        assertEq(recipientBalance, dustAmount, "Recipient should get dust");

        // Verify launchpad has 0
        uint256 remainingDust = IERC20(latestAsset).balanceOf(address(launchpad));
        assertEq(remainingDust, 0, "Launchpad should have 0");

    }

    function test_Sweep_ETH() public {

        // Send some ETH to launchpad
        uint256 ethAmount = 1 ether;
        vm.deal(address(launchpad), ethAmount);


        uint256 recipientBalanceBefore = recipient.balance;

        // Owner sweeps ETH to recipient
        launchpad.sweep(address(0), recipient);

        // Verify recipient got ETH
        uint256 recipientBalanceAfter = recipient.balance;
        assertEq(recipientBalanceAfter - recipientBalanceBefore, ethAmount, "Recipient should get ETH");

        // Verify launchpad has 0 ETH
        assertEq(address(launchpad).balance, 0, "Launchpad should have 0 ETH");

    }

    function test_Sweep_OnlyOwner() public {

        // Launch token to get some dust
        NoiceCreatorAllocation[] memory locks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(locks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);

        // Check launchpad has some dust
        uint256 dustAmount = IERC20(latestAsset).balanceOf(address(launchpad));
        assertGt(dustAmount, 0, "Should have dust");

        // Attacker tries to sweep
        vm.prank(attacker);
        vm.expectRevert();
        launchpad.sweep(latestAsset, attacker);

        // Verify dust still in launchpad
        uint256 remainingDust = IERC20(latestAsset).balanceOf(address(launchpad));
        assertEq(remainingDust, dustAmount, "Dust should remain in launchpad");

    }

    function test_Sweep_NoiceToken() public {

        // Send some NOICE to launchpad
        uint256 noiceAmount = 1000e18;
        deal(NOICE_TOKEN, address(launchpad), noiceAmount);


        // Owner sweeps NOICE to recipient
        launchpad.sweep(NOICE_TOKEN, recipient);

        // Verify recipient got NOICE
        uint256 recipientBalance = IERC20(NOICE_TOKEN).balanceOf(recipient);
        assertEq(recipientBalance, noiceAmount, "Recipient should get NOICE");

        // Verify launchpad has 0 NOICE
        uint256 remainingNoice = IERC20(NOICE_TOKEN).balanceOf(address(launchpad));
        assertEq(remainingNoice, 0, "Launchpad should have 0 NOICE");

    }

    function test_Sweep_NoBalance() public {

        // Try to sweep when there's nothing
        launchpad.sweep(NOICE_TOKEN, recipient);

        // Should not revert, just no-op
    }
}
