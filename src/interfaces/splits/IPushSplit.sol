// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPushSplit {
    function getSplitConfiguration()
        external
        view
        returns (address[] memory recipients, uint256[] memory allocations, uint256 totalAllocation, uint16 distributionIncentive);
}
