// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPushSplitFactory {
    struct Split {
        address[] recipients;
        uint256[] allocations;
        uint256 totalAllocation;
        uint16 distributionIncentive;
    }

    function createSplit(Split calldata split, address owner, address distributor) external returns (address splitAddress);
}
