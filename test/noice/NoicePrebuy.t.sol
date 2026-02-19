// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    BundleWithVestingParams,
    NoiceCreatorAllocation,
    NoicePrebuyParticipant,
    PrebuyDisabled
} from "src/NoiceLaunchpad.sol";

/**
 * @title NoicePrebuyTest
 * @notice Verifies that prebuy is disabled while launch remains functional
 */
contract NoicePrebuyTest is NoiceBaseTest {
    address public participant = makeAddr("participant");
    address public latestAsset;

    function test_PrebuyDisabled_EmptyPayloadStillLaunches() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);

        vm.prank(participant);
        launchpad.bundleWithCreatorVesting(params, participants);

        latestAsset = _computeAssetAddress(params.createData.salt);
        assertNotEq(latestAsset, address(0), "Asset should be deployed");
        assertEq(launchpad.assetCreator(latestAsset), participant, "Creator should be launch caller");
    }

    function test_PrebuyDisabled_RevertsWhenParticipantsProvided() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);

        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](1);
        participants[0] = NoicePrebuyParticipant({
            lockedAddress: participant,
            noiceAmount: 1e18,
            vestingStartTimestamp: uint40(block.timestamp),
            vestingEndTimestamp: uint40(block.timestamp + 1 days),
            vestingRecipient: participant
        });

        vm.expectRevert(PrebuyDisabled.selector);
        launchpad.bundleWithCreatorVesting(params, participants);
    }

    function test_PrebuyDisabled_RevertsWhenCommandsProvided() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        params.noicePrebuyCommands = hex"00";

        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);
        vm.expectRevert(PrebuyDisabled.selector);
        launchpad.bundleWithCreatorVesting(params, participants);
    }

    function test_PrebuyDisabled_RevertsWhenInputsProvided() public {
        NoiceCreatorAllocation[] memory noiceCreatorLocks = new NoiceCreatorAllocation[](0);
        BundleWithVestingParams memory params = _createBundleParams(noiceCreatorLocks);
        params.noicePrebuyInputs = new bytes[](1);
        params.noicePrebuyInputs[0] = abi.encodePacked(uint256(1));

        NoicePrebuyParticipant[] memory participants = new NoicePrebuyParticipant[](0);
        vm.expectRevert(PrebuyDisabled.selector);
        launchpad.bundleWithCreatorVesting(params, participants);
    }
}
