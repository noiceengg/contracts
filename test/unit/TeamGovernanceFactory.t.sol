// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TeamGovernanceFactory } from "src/TeamGovernanceFactory.sol";

contract TeamGovernanceFactoryTest is Test {
    TeamGovernanceFactory public governanceFactory;

    address public constant DEAD_ADDRESS = address(0xdead);
    address public mockTeamWallet;
    address public mockAsset;

    function setUp() public {
        governanceFactory = new TeamGovernanceFactory();
        mockTeamWallet = makeAddr("teamWallet");
        mockAsset = makeAddr("asset");
    }

    function testCreate() public {
        bytes memory data = abi.encode(mockTeamWallet);

        (address governance, address timelockController) = governanceFactory.create(mockAsset, data);

        assertEq(governance, DEAD_ADDRESS);
        assertEq(timelockController, mockTeamWallet);
    }

    function testCreateWithDifferentTeamWallet() public {
        address anotherTeamWallet = makeAddr("anotherTeamWallet");
        bytes memory data = abi.encode(anotherTeamWallet);

        (address governance, address timelockController) = governanceFactory.create(mockAsset, data);

        assertEq(governance, DEAD_ADDRESS);
        assertEq(timelockController, anotherTeamWallet);
    }

    function testCreateWithZeroAddress() public {
        bytes memory data = abi.encode(address(0));

        (address governance, address timelockController) = governanceFactory.create(mockAsset, data);

        assertEq(governance, DEAD_ADDRESS);
        assertEq(timelockController, address(0));
    }

    function testDeadAddressConstant() public {
        assertEq(governanceFactory.DEAD_ADDRESS(), DEAD_ADDRESS);
    }

    function testCreateIgnoresAssetParameter() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        bytes memory data = abi.encode(mockTeamWallet);

        (address governance1, address timelock1) = governanceFactory.create(asset1, data);
        (address governance2, address timelock2) = governanceFactory.create(asset2, data);

        assertEq(governance1, governance2);
        assertEq(timelock1, timelock2);
        assertEq(governance1, DEAD_ADDRESS);
        assertEq(timelock1, mockTeamWallet);
    }

    function testFuzzCreate(address teamWallet, address asset) public {
        bytes memory data = abi.encode(teamWallet);

        (address governance, address timelockController) = governanceFactory.create(asset, data);

        assertEq(governance, DEAD_ADDRESS);
        assertEq(timelockController, teamWallet);
    }
}