// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { NoiceBaseTest } from "./NoiceBaseTest.sol";
import { BundleParams, NumeraireCreatorAllocation } from "src/NoiceLaunchpad.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

contract MockTarget {
    event Called(address caller, uint256 value, bytes data);

    uint256 public counter;

    function increment() external returns (uint256) {
        counter++;
        emit Called(msg.sender, 0, msg.data);
        return counter;
    }

    function incrementWithValue() external payable returns (uint256) {
        counter += msg.value;
        emit Called(msg.sender, msg.value, msg.data);
        return counter;
    }

    function revertFunction() external pure {
        revert("Intentional revert");
    }
}

/**
 * @title NoiceExecuteTest
 * @notice Tests execute functionality for arbitrary calldata execution from launchpad
 */
contract NoiceExecuteTest is NoiceBaseTest {
    MockTarget public target1;
    MockTarget public target2;
    address public attacker = makeAddr("attacker");
    address public latestAsset;

    function setUp() public override {
        super.setUp();
        target1 = new MockTarget();
        target2 = new MockTarget();
    }

    function test_Execute_SingleCall() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(target1);
        values[0] = 0;
        data[0] = abi.encodeWithSelector(MockTarget.increment.selector);

        bytes[] memory results = launchpad.execute(targets, values, data);

        assertEq(target1.counter(), 1, "Counter should be 1");
        assertEq(abi.decode(results[0], (uint256)), 1, "Should return 1");
    }

    function test_Execute_BatchCalls() public {
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = address(target1);
        values[0] = 0;
        data[0] = abi.encodeWithSelector(MockTarget.increment.selector);

        targets[1] = address(target2);
        values[1] = 0;
        data[1] = abi.encodeWithSelector(MockTarget.increment.selector);

        targets[2] = address(target1);
        values[2] = 0;
        data[2] = abi.encodeWithSelector(MockTarget.increment.selector);

        bytes[] memory results = launchpad.execute(targets, values, data);

        assertEq(target1.counter(), 2, "Target1 counter should be 2");
        assertEq(target2.counter(), 1, "Target2 counter should be 1");
        assertEq(abi.decode(results[0], (uint256)), 1, "First call should return 1");
        assertEq(abi.decode(results[1], (uint256)), 1, "Second call should return 1");
        assertEq(abi.decode(results[2], (uint256)), 2, "Third call should return 2");
    }

    function test_Execute_WithValue() public {
        // Fund launchpad with ETH
        vm.deal(address(launchpad), 10 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(target1);
        values[0] = 5 ether;
        data[0] = abi.encodeWithSelector(MockTarget.incrementWithValue.selector);

        bytes[] memory results = launchpad.execute(targets, values, data);

        assertEq(target1.counter(), 5 ether, "Counter should be 5 ether");
        assertEq(abi.decode(results[0], (uint256)), 5 ether, "Should return 5 ether");
    }

    function test_Execute_TokenTransfer() public {
        // Launch token to get some dust
        NumeraireCreatorAllocation[] memory locks = new NumeraireCreatorAllocation[](0);
        BundleParams memory params = _createBundleParams(locks);
        
        launchpad.bundleWithCreatorAllocations(params);
        latestAsset = _computeAssetAddress(params.createData.salt);

        uint256 dustAmount = IERC20(latestAsset).balanceOf(address(launchpad));
        assertGt(dustAmount, 0, "Should have dust");

        address recipient = makeAddr("recipient");

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = latestAsset;
        values[0] = 0;
        data[0] = abi.encodeWithSelector(IERC20.transfer.selector, recipient, dustAmount);

        launchpad.execute(targets, values, data);

        assertEq(IERC20(latestAsset).balanceOf(recipient), dustAmount, "Recipient should get tokens");
        assertEq(IERC20(latestAsset).balanceOf(address(launchpad)), 0, "Launchpad should have 0");
    }

    function test_Execute_OnlyOwner() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(target1);
        values[0] = 0;
        data[0] = abi.encodeWithSelector(MockTarget.increment.selector);

        vm.prank(attacker);
        vm.expectRevert();
        launchpad.execute(targets, values, data);

        assertEq(target1.counter(), 0, "Counter should still be 0");
    }

    function test_Execute_ExecutorRoleCannotCall() public {
        address executor = makeAddr("executor");
        launchpad.grantRoles(executor, launchpad.EXECUTOR_ROLE());

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(target1);
        values[0] = 0;
        data[0] = abi.encodeWithSelector(MockTarget.increment.selector);

        vm.prank(executor);
        vm.expectRevert();
        launchpad.execute(targets, values, data);

        assertEq(target1.counter(), 0, "Counter should still be 0");
    }

    function test_Execute_RevertsOnLengthMismatch() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](2);

        vm.expectRevert("Length mismatch");
        launchpad.execute(targets, values, data);
    }

    function test_Execute_RevertsOnCallFailure() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(target1);
        values[0] = 0;
        data[0] = abi.encodeWithSelector(MockTarget.revertFunction.selector);

        vm.expectRevert("Intentional revert");
        launchpad.execute(targets, values, data);
    }

    function test_Execute_EmptyBatch() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory data = new bytes[](0);

        bytes[] memory results = launchpad.execute(targets, values, data);
        assertEq(results.length, 0, "Should return empty results");
    }
}
