// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

error VestingNotStarted();
error NothingToClaim();
contract SimpleLinearVesting {
    address public immutable token;
    address public immutable beneficiary;
    uint64 public immutable start;
    uint64 public immutable duration;

    uint256 public claimed;

    constructor(address token_, address beneficiary_, uint64 start_, uint64 duration_) {
        token = token_;
        beneficiary = beneficiary_;
        start = start_;
        duration = duration_;
    }
    function vestedAmount() public view returns (uint256) {
        uint256 balance = ERC20(token).balanceOf(address(this));
        uint256 total = balance + claimed;

        if (block.timestamp < start) return 0;
        if (duration == 0) return total;

        uint256 elapsed = block.timestamp - uint256(start);
        if (elapsed >= duration) return total;

        return (total * elapsed) / duration;
    }
    function claim() external {
        if (block.timestamp < start) revert VestingNotStarted();
        uint256 available = vestedAmount() - claimed;
        if (available == 0) revert NothingToClaim();
        claimed += available;
        ERC20(token).transfer(beneficiary, available);
    }
}
