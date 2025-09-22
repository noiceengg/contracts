// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

contract MockSablierV2LockupLinear {
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
    struct Stream {
        address asset;
        address recipient;
        uint40 start;
        uint40 duration;
        uint128 total;
        uint128 withdrawn;
        address sender;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Stream) public streams;

    event StreamCreated(uint256 indexed id, address indexed asset, address indexed recipient, uint128 amount);
    event Withdraw(uint256 indexed id, address to, uint128 amount);

    function createWithDurations(CreateWithDurations calldata p) external returns (uint256 streamId) {
        // Pull funds from the declared sender
        ERC20(p.asset).transferFrom(p.sender, address(this), p.totalAmount);
        streamId = nextId++;
        streams[streamId] = Stream({
            asset: p.asset,
            recipient: p.recipient.account,
            start: p.startTime,
            duration: p.totalDuration,
            total: p.totalAmount,
            withdrawn: 0,
            sender: p.sender
        });
        emit StreamCreated(streamId, p.asset, p.recipient.account, p.totalAmount);
    }

    function vested(uint256 id) public view returns (uint128) {
        Stream memory s = streams[id];
        if (block.timestamp < s.start) return 0;
        if (s.duration == 0) return s.total;
        uint256 elapsed = block.timestamp - uint256(s.start);
        if (elapsed >= s.duration) return s.total;
        return uint128((uint256(s.total) * elapsed) / s.duration);
    }

    function withdraw(uint256 id, address to) external returns (uint128 amt) {
        Stream storage s = streams[id];
        require(msg.sender == s.recipient, "not recipient");
        uint128 available = vested(id) - s.withdrawn;
        require(available > 0, "nothing to withdraw");
        s.withdrawn += available;
        ERC20(s.asset).transfer(to, available);
        emit Withdraw(id, to, available);
        return available;
    }
}

