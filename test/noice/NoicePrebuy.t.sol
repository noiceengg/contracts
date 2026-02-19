// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import {
    BundleParams,
    NumeraireCreatorAllocation,
    NumerairePrebuyCommit,
    NumerairePrebuyReveal,
    PrebuyTranche
} from "src/NoiceLaunchpad.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

contract NoicePrebuyTest is NoiceBaseTest {
    address public fundingWallet = makeAddr("fundingWallet");
    address public revealCaller = makeAddr("revealCaller");
    address public recipient = makeAddr("recipient");

    function test_PrebuyCommitRevealByDifferentCaller() public {
        BundleParams memory params = _createBundleWithSingleTranche();
        launchpad.bundleWithCreatorAllocations(params);
        address asset = _computeAssetAddress(params.createData.salt);

        uint256 trancheId = 0;
        uint256 amount = 1e18;
        bytes32 salt = keccak256("salt");

        bytes32 commitment = keccak256(
            abi.encode(asset, trancheId, fundingWallet, amount, recipient, false, uint40(0), uint40(0), salt)
        );

        vm.warp(block.timestamp + 1);
        launchpad.commitPrebuy(
            asset,
            NumerairePrebuyCommit({ commitment: commitment, fundingWallet: fundingWallet, trancheId: trancheId })
        );

        deal(NOICE_TOKEN, fundingWallet, amount);
        vm.prank(fundingWallet);
        IERC20(NOICE_TOKEN).approve(address(launchpad), amount);

        vm.warp(block.timestamp + 11);
        vm.prank(revealCaller);
        launchpad.revealPrebuy(
            asset,
            NumerairePrebuyReveal({
                fundingWallet: fundingWallet,
                trancheId: trancheId,
                numeraireAmount: amount,
                recipient: recipient,
                useVesting: false,
                vestingStartTimestamp: 0,
                vestingEndTimestamp: 0,
                salt: salt
            })
        );
    }

    function test_PrebuyRevealFailsForWrongFundingWallet() public {
        BundleParams memory params = _createBundleWithSingleTranche();
        launchpad.bundleWithCreatorAllocations(params);
        address asset = _computeAssetAddress(params.createData.salt);

        uint256 trancheId = 0;
        uint256 amount = 1e18;
        bytes32 salt = keccak256("salt");

        bytes32 commitment = keccak256(
            abi.encode(asset, trancheId, fundingWallet, amount, recipient, false, uint40(0), uint40(0), salt)
        );
        launchpad.commitPrebuy(
            asset,
            NumerairePrebuyCommit({ commitment: commitment, fundingWallet: fundingWallet, trancheId: trancheId })
        );

        vm.warp(block.timestamp + 11);
        vm.expectRevert();
        launchpad.revealPrebuy(
            asset,
            NumerairePrebuyReveal({
                fundingWallet: revealCaller,
                trancheId: trancheId,
                numeraireAmount: amount,
                recipient: recipient,
                useVesting: false,
                vestingStartTimestamp: 0,
                vestingEndTimestamp: 0,
                salt: salt
            })
        );
    }

    function _createBundleWithSingleTranche() internal view returns (BundleParams memory params) {
        NumeraireCreatorAllocation[] memory creatorAllocations = new NumeraireCreatorAllocation[](0);
        params = _createBundleParams(creatorAllocations);
        params.prebuyTranches = new PrebuyTranche[](1);
        params.prebuyTranches[0] = PrebuyTranche({
            commitStart: uint40(block.timestamp),
            commitEnd: uint40(block.timestamp + 10),
            revealStart: uint40(block.timestamp + 11),
            revealEnd: uint40(block.timestamp + 20),
            assetAllocation: 1_000e18
        });
    }
}
