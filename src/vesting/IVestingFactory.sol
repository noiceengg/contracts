// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IVestingFactory {
    // Creates a vesting stream for `amount` and returns an address representing the vesting target
    // (typically the Sablier contract address).
    function create(
        address token,
        address beneficiary,
        uint128 amount,
        uint64 start,
        uint64 duration
    ) external returns (address vestingTarget);
}
