// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IVestingFactory } from "src/vesting/IVestingFactory.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

// Minimal Sablier V2 Lockup Linear interface
interface ISablierV2LockupLinear {
    struct Recipient {
        address account;
        bool cancelable;
        bool transferable;
    }
    struct CreateWithDurations {
        address asset;
        uint128 totalAmount;
        uint40 startTime;
        uint40 cliffDuration;
        uint40 totalDuration;
        Recipient recipient;
        address sender;
    }
    function createWithDurations(CreateWithDurations calldata params) external returns (uint256 streamId);
}

// Wraps Sablier V2 Lockup Linear to satisfy IVestingFactory. It creates a stream and
// returns a pseudo-vesting address represented by this factory (not a claimable contract).
// Note: Integrators should track the returned streamId via events or an extended interface.
contract SablierVestingFactory is IVestingFactory {
    ISablierV2LockupLinear public immutable sablier;

    event SablierStreamCreated(address indexed token, address indexed beneficiary, uint256 streamId, uint256 amount);

    constructor(address sablier_) {
        sablier = ISablierV2LockupLinear(sablier_);
    }

    function create(
        address token,
        address beneficiary,
        uint128 amount,
        uint64 start,
        uint64 duration
    ) external returns (address vestingTarget) {
        // Approve the Sablier contract to pull funds from this factory
        ERC20(token).approve(address(sablier), amount);
        uint256 streamId = sablier.createWithDurations(
            ISablierV2LockupLinear.CreateWithDurations({
                asset: token,
                totalAmount: amount,
                startTime: uint40(start),
                cliffDuration: 0,
                totalDuration: uint40(duration),
                recipient: ISablierV2LockupLinear.Recipient({
                    account: beneficiary,
                    cancelable: false,
                    transferable: false
                }),
                sender: address(this)
            })
        );
        emit SablierStreamCreated(token, beneficiary, streamId, amount);
        return address(sablier);
    }
}
