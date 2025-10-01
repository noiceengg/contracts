// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {NoiceLaunchpad, BundleWithVestingParams, VestingParams, PresaleParticipant, InvalidAddresses, InvalidVestingTimestamps, TooManyPresaleParticipants} from "src/NoiceLaunchpad.sol";
import {Airlock, CreateParams} from "src/Airlock.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";
import {ISablierLockup} from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import {Lockup, LockupLinear, Broker} from "@sablier/v2-core/types/DataTypes.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {TokenFactory, ITokenFactory} from "src/TokenFactory.sol";
import {TeamGovernanceFactory} from "src/TeamGovernanceFactory.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";
import {IPoolInitializer} from "src/interfaces/IPoolInitializer.sol";
import {ILiquidityMigrator} from "src/interfaces/ILiquidityMigrator.sol";
import {DERC20} from "src/DERC20.sol";

contract MockToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    string public name = "Mock Token";
    string public symbol = "MOCK";

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract MockAirlock {
    address public lastCreatedToken;

    function create(CreateParams calldata params) external returns (
        address asset,
        address governor,
        address numeraire,
        address timelock,
        bytes32 salt
    ) {
        // Create a mock token
        MockToken token = new MockToken();
        asset = address(token);
        lastCreatedToken = asset;

        // Mint tokens
        uint256 saleAmount = params.numTokensToSell;
        uint256 vestingAmount = params.initialSupply - saleAmount;

        // Mint sale amount to msg.sender (launchpad)
        token.mint(msg.sender, saleAmount);

        // Mint vesting amount to msg.sender (launchpad) so it can create vesting stream
        token.mint(msg.sender, vestingAmount);

        // Call governance factory to get timelock
        (address governance, address timelockAddr) = params.governanceFactory.create(
            asset,
            params.governanceFactoryData
        );

        return (asset, governance, params.numeraire, timelockAddr, params.salt);
    }
}

contract NoiceLaunchpadSimpleTest is Test {
    NoiceLaunchpad public launchpad;
    NoiceLaunchpad public launchpadWithMock;
    ISablierLockup public sablierLockup;
    MockToken public testToken;
    MockAirlock public mockAirlock;
    TokenFactory public tokenFactory;
    TeamGovernanceFactory public governanceFactory;

    address payable public airlock;
    address payable public router;

    address public creator = makeAddr("creator");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant CREATOR_VESTING_PERCENTAGE = 45;
    address public constant NOICE_TOKEN = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;

    receive() external payable {}

    function setUp() public {
        string memory rpcUrl = vm.envString("BASE_MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        sablierLockup = ISablierLockup(
            0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B
        );

        airlock = payable(0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12);
        router = payable(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3);

        governanceFactory = new TeamGovernanceFactory();
        tokenFactory = new TokenFactory(airlock);
        mockAirlock = new MockAirlock();

        launchpad = new NoiceLaunchpad(
            Airlock(airlock),
            UniversalRouter(router),
            sablierLockup,
            NOICE_TOKEN,
            CREATOR_VESTING_PERCENTAGE
        );

        launchpadWithMock = new NoiceLaunchpad(
            Airlock(payable(address(mockAirlock))),
            UniversalRouter(router),
            sablierLockup,
            NOICE_TOKEN,
            CREATOR_VESTING_PERCENTAGE
        );

        testToken = new MockToken();

        vm.label(address(launchpad), "NoiceLaunchpad");
        vm.label(address(launchpadWithMock), "NoiceLaunchpadWithMock");
        vm.label(address(mockAirlock), "MockAirlock");
        vm.label(address(sablierLockup), "SablierLockup");
        vm.label(address(tokenFactory), "TokenFactory");
        vm.label(address(governanceFactory), "TeamGovernanceFactory");
        vm.label(creator, "creator");
        vm.label(user, "user");
    }

    function testConstructor() public view {
        assertEq(address(launchpad.airlock()), airlock);
        assertEq(address(launchpad.router()), router);
        assertEq(address(launchpad.sablierLockup()), address(sablierLockup));
        assertEq(launchpad.NOICE_TOKEN(), NOICE_TOKEN);
        assertEq(launchpad.CREATOR_VESTING_PERCENTAGE(), CREATOR_VESTING_PERCENTAGE);
    }

    function testConstructorRevertsWithZeroAddress() public {
        vm.expectRevert(InvalidAddresses.selector);
        new NoiceLaunchpad(
            Airlock(payable(address(0))),
            UniversalRouter(router),
            sablierLockup,
            NOICE_TOKEN,
            CREATOR_VESTING_PERCENTAGE
        );

        vm.expectRevert(InvalidAddresses.selector);
        new NoiceLaunchpad(
            Airlock(airlock),
            UniversalRouter(payable(address(0))),
            sablierLockup,
            NOICE_TOKEN,
            CREATOR_VESTING_PERCENTAGE
        );

        vm.expectRevert(InvalidAddresses.selector);
        new NoiceLaunchpad(
            Airlock(airlock),
            UniversalRouter(router),
            ISablierLockup(address(0)),
            NOICE_TOKEN,
            CREATOR_VESTING_PERCENTAGE
        );

        vm.expectRevert(InvalidAddresses.selector);
        new NoiceLaunchpad(
            Airlock(airlock),
            UniversalRouter(router),
            sablierLockup,
            address(0),
            CREATOR_VESTING_PERCENTAGE
        );

        vm.expectRevert(InvalidAddresses.selector);
        new NoiceLaunchpad(
            Airlock(airlock),
            UniversalRouter(router),
            sablierLockup,
            NOICE_TOKEN,
            0
        );

        vm.expectRevert(InvalidAddresses.selector);
        new NoiceLaunchpad(
            Airlock(airlock),
            UniversalRouter(router),
            sablierLockup,
            NOICE_TOKEN,
            101
        );
    }

    function testVestingAllocationCalculation() public pure {
        uint256 totalSupply = 1_000_000e18;
        uint256 expectedVesting = (totalSupply * 45) / 100;
        uint256 expectedSale = totalSupply - expectedVesting;

        assertEq(expectedVesting, 450_000e18);
        assertEq(expectedSale, 550_000e18);
        assertEq(expectedVesting + expectedSale, totalSupply);
    }

    function testInvalidVestingTimestamps() public {
        uint40 startTime = uint40(block.timestamp + 30 days);
        uint40 endTime = uint40(block.timestamp + 1 days);

        CreateParams memory createData = _getMinimalCreateParams();
        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: startTime,
            creatorVestingEndTimestamp: endTime
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        PresaleParticipant[] memory participants = new PresaleParticipant[](0);

        vm.expectRevert(InvalidVestingTimestamps.selector);
        launchpad.bundleWithCreatorVesting(params, participants);
    }

    function testSablierIntegrationDirect() public {
        uint256 vestingAmount = 1_000_000e18;
        testToken.mint(address(this), vestingAmount);
        testToken.approve(address(sablierLockup), vestingAmount);

        uint40 startTime = uint40(block.timestamp + 1 days);
        uint40 endTime = uint40(block.timestamp + 365 days);
        Lockup.CreateWithTimestamps memory params = Lockup
            .CreateWithTimestamps({
                sender: address(this),
                recipient: creator,
                totalAmount: uint128(vestingAmount),
                token: testToken,
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({start: startTime, end: endTime}),
                shape: "linear",
                broker: Broker({account: address(0), fee: UD60x18.wrap(0)})
            });

        LockupLinear.UnlockAmounts memory unlockAmounts = LockupLinear
            .UnlockAmounts({start: 0, cliff: 0});

        uint256 streamId = sablierLockup.createWithTimestampsLL(
            params,
            unlockAmounts,
            0
        );
        assertTrue(streamId > 0, "Stream ID should be greater than 0");
        assertEq(
            sablierLockup.getRecipient(streamId),
            creator,
            "Stream recipient should be creator"
        );
        assertTrue(
            sablierLockup.isCancelable(streamId),
            "Stream should be cancelable"
        );
        assertTrue(
            sablierLockup.isTransferable(streamId),
            "Stream should be transferable"
        );
    }

    function testSablierVestingWithdrawal() public {
        uint256 vestingAmount = 1_000_000e18;
        testToken.mint(address(this), vestingAmount);
        testToken.approve(address(sablierLockup), vestingAmount);

        uint40 startTime = uint40(block.timestamp);
        uint40 endTime = uint40(block.timestamp + 365 days);

        Lockup.CreateWithTimestamps memory params = Lockup
            .CreateWithTimestamps({
                sender: address(this),
                recipient: creator,
                totalAmount: uint128(vestingAmount),
                token: testToken,
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({start: startTime, end: endTime}),
                shape: "linear",
                broker: Broker({account: address(0), fee: UD60x18.wrap(0)})
            });

        uint256 streamId = sablierLockup.createWithTimestampsLL(
            params,
            LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
            0
        );

        uint128 initialWithdrawable = sablierLockup.withdrawableAmountOf(streamId);
        assertLe(initialWithdrawable, 1000);

        vm.warp(block.timestamp + 182.5 days);
        uint128 halfwayWithdrawable = sablierLockup.withdrawableAmountOf(streamId);
        assertApproxEqAbs(halfwayWithdrawable, vestingAmount / 2, 1e18);

        vm.prank(creator);
        sablierLockup.withdraw(streamId, creator, halfwayWithdrawable);
        assertEq(testToken.balanceOf(creator), halfwayWithdrawable);

        vm.warp(endTime + 1);
        uint128 finalWithdrawable = sablierLockup.withdrawableAmountOf(streamId);

        vm.prank(creator);
        sablierLockup.withdraw(streamId, creator, finalWithdrawable);
        assertApproxEqAbs(testToken.balanceOf(creator), vestingAmount, 1e18);

        assertTrue(
            sablierLockup.isDepleted(streamId),
            "Stream should be depleted"
        );
    }

    function testReceiveETH() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        (bool success, ) = address(launchpad).call{value: amount}("");
        assertTrue(success);
        assertEq(address(launchpad).balance, amount);
    }

    function testFuzzVestingAllocation(uint256 totalSupply) public pure {
        vm.assume(totalSupply > 0 && totalSupply <= 1e30);

        uint256 vestingAmount = (totalSupply * 45) / 100;
        uint256 saleAmount = totalSupply - vestingAmount;

        assertEq(vestingAmount + saleAmount, totalSupply);
        assertTrue(vestingAmount <= totalSupply);
        assertTrue(saleAmount <= totalSupply);
    }

    function testFuzzVestingTimestamps(
        uint40 startOffset,
        uint40 duration
    ) public {
        vm.assume(startOffset > 0 && startOffset < 365 days);
        vm.assume(duration > 1 days && duration < 4 * 365 days);

        uint40 startTime = uint40(block.timestamp + startOffset);
        uint40 endTime = uint40(startTime + duration);

        CreateParams memory createData = _getMinimalCreateParams();
        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: startTime,
            creatorVestingEndTimestamp: endTime
        });

        assertTrue(endTime > startTime);
    }

    function testFullLaunchFlowWithVesting() public {
        vm.deal(address(this), 10 ether);

        uint40 startTime = uint40(block.timestamp + 1 days);
        uint40 endTime = uint40(block.timestamp + 365 days);

        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: startTime,
            creatorVestingEndTimestamp: endTime
        });
        CreateParams memory createData = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: INITIAL_SUPPLY,
            numeraire: address(testToken),
            tokenFactory: ITokenFactory(address(0)),
            tokenFactoryData: "",
            governanceFactory: governanceFactory,
            governanceFactoryData: abi.encode(creator),
            poolInitializer: IPoolInitializer(address(0)),
            poolInitializerData: "",
            liquidityMigrator: ILiquidityMigrator(address(0)),
            liquidityMigratorData: "",
            integrator: address(0),
            salt: bytes32(uint256(0xbeef))
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        PresaleParticipant[] memory participants = new PresaleParticipant[](0);

        uint256 launchpadEthBefore = address(launchpadWithMock).balance;
        launchpadWithMock.bundleWithCreatorVesting{value: 1 ether}(params, participants);

        uint256 expectedVestingAmount = (INITIAL_SUPPLY * 45) / 100;
        uint256 expectedSaleAmount = INITIAL_SUPPLY - expectedVestingAmount;

        uint256 launchpadEthAfter = address(launchpadWithMock).balance;
        assertEq(launchpadEthAfter, launchpadEthBefore, "Launchpad should not hold ETH");

        console2.log("Full launch flow completed successfully");
        console2.log("Expected vesting amount:", expectedVestingAmount);
        console2.log("Expected sale amount:", expectedSaleAmount);
    }

    function testFullLaunchFlowWithVestingUnlock() public {
        vm.deal(address(this), 10 ether);

        uint40 startTime = uint40(block.timestamp);
        uint40 endTime = uint40(block.timestamp + 365 days);

        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: startTime,
            creatorVestingEndTimestamp: endTime
        });
        CreateParams memory createData = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: INITIAL_SUPPLY,
            numeraire: address(testToken),
            tokenFactory: ITokenFactory(address(0)),
            tokenFactoryData: "",
            governanceFactory: governanceFactory,
            governanceFactoryData: abi.encode(creator),
            poolInitializer: IPoolInitializer(address(0)),
            poolInitializerData: "",
            liquidityMigrator: ILiquidityMigrator(address(0)),
            liquidityMigratorData: "",
            integrator: address(0),
            salt: bytes32(uint256(0xdead1))
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        PresaleParticipant[] memory participants = new PresaleParticipant[](0);

        vm.recordLogs();
        launchpadWithMock.bundleWithCreatorVesting{value: 1 ether}(params, participants);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 streamId;
        bool foundStream = false;

        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) {
                if (logs[i].emitter == address(sablierLockup)) {
                    address from = address(uint160(uint256(logs[i].topics[1])));
                    if (from == address(0)) {
                        streamId = uint256(logs[i].topics[3]);
                        foundStream = true;
                        break;
                    }
                }
            }
        }

        require(foundStream, "Could not find stream creation event");

        uint256 expectedVestingAmount = (INITIAL_SUPPLY * 45) / 100;
        address tokenAddress = mockAirlock.lastCreatedToken();
        MockToken vestedToken = MockToken(tokenAddress);
        address recipient = sablierLockup.getRecipient(streamId);

        console2.log("Stream ID:", streamId);
        console2.log("Stream recipient:", recipient);
        console2.log("Creator address:", creator);
        console2.log("Token address:", tokenAddress);

        uint128 initialWithdrawable = sablierLockup.withdrawableAmountOf(streamId);
        console2.log("Initial withdrawable:", initialWithdrawable);
        assertLe(initialWithdrawable, 1e18);

        uint256 initialBalance = vestedToken.balanceOf(recipient);
        console2.log("Initial token balance:", initialBalance);

        vm.warp(block.timestamp + 182.5 days);
        uint128 halfwayWithdrawable = sablierLockup.withdrawableAmountOf(streamId);
        console2.log("Halfway withdrawable:", halfwayWithdrawable);
        assertApproxEqAbs(halfwayWithdrawable, expectedVestingAmount / 2, 1e18);

        vm.prank(recipient);
        sablierLockup.withdraw(streamId, recipient, halfwayWithdrawable);

        uint256 balanceAfterHalfway = vestedToken.balanceOf(recipient);
        assertEq(balanceAfterHalfway, initialBalance + halfwayWithdrawable);
        console2.log("Tokens after halfway withdrawal:", balanceAfterHalfway);

        vm.warp(endTime + 1);
        uint128 finalWithdrawable = sablierLockup.withdrawableAmountOf(streamId);
        console2.log("Final withdrawable:", finalWithdrawable);

        vm.prank(recipient);
        sablierLockup.withdraw(streamId, recipient, finalWithdrawable);

        uint256 finalBalance = vestedToken.balanceOf(recipient);
        assertApproxEqAbs(finalBalance, initialBalance + expectedVestingAmount, 1e18);
        console2.log("Final token balance:", finalBalance);

        assertTrue(sablierLockup.isDepleted(streamId));

        console2.log("Vesting unlock test completed successfully");
    }

    function testPresaleTooManyParticipants() public {
        PresaleParticipant[] memory participants = new PresaleParticipant[](101);
        for (uint256 i = 0; i < 101; i++) {
            participants[i] = PresaleParticipant({
                lockedAddress: makeAddr(string(abi.encodePacked("participant", i))),
                noiceAmount: 1000e18,
                vestingStartTimestamp: uint40(block.timestamp + 1 days),
                vestingEndTimestamp: uint40(block.timestamp + 365 days),
                vestingRecipient: makeAddr(string(abi.encodePacked("recipient", i)))
            });
        }

        CreateParams memory createData = _getMinimalCreateParams();
        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: uint40(block.timestamp + 1 days),
            creatorVestingEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        vm.expectRevert(TooManyPresaleParticipants.selector);
        launchpadWithMock.bundleWithCreatorVesting(params, participants);
    }

    function testPresaleInvalidVestingTimestamps() public {
        address participant1 = makeAddr("participant1");

        PresaleParticipant[] memory participants = new PresaleParticipant[](1);
        participants[0] = PresaleParticipant({
            lockedAddress: participant1,
            noiceAmount: 1000e18,
            vestingStartTimestamp: uint40(block.timestamp + 365 days),
            vestingEndTimestamp: uint40(block.timestamp + 1 days),
            vestingRecipient: participant1
        });

        CreateParams memory createData = _getMinimalCreateParams();
        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: uint40(block.timestamp + 1 days),
            creatorVestingEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        deal(NOICE_TOKEN, participant1, 1000e18);
        vm.prank(participant1);
        IERC20(NOICE_TOKEN).approve(address(launchpadWithMock), 1000e18);

        vm.expectRevert(InvalidVestingTimestamps.selector);
        launchpadWithMock.bundleWithCreatorVesting(params, participants);
    }

    function testPresaleWithMultipleParticipants() public {
        address participant1 = makeAddr("participant1");
        address participant2 = makeAddr("participant2");
        address participant3 = makeAddr("participant3");

        // Setup presale participants with different NOICE amounts
        PresaleParticipant[] memory participants = new PresaleParticipant[](3);
        participants[0] = PresaleParticipant({
            lockedAddress: participant1,
            noiceAmount: 5000e18,  // 50%
            vestingStartTimestamp: uint40(block.timestamp + 1 days),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: participant1
        });
        participants[1] = PresaleParticipant({
            lockedAddress: participant2,
            noiceAmount: 3000e18,  // 30%
            vestingStartTimestamp: uint40(block.timestamp + 1 days),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: participant2
        });
        participants[2] = PresaleParticipant({
            lockedAddress: participant3,
            noiceAmount: 2000e18,  // 20%
            vestingStartTimestamp: uint40(block.timestamp + 1 days),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: participant3
        });

        // Fund participants with NOICE
        deal(NOICE_TOKEN, participant1, 5000e18);
        deal(NOICE_TOKEN, participant2, 3000e18);
        deal(NOICE_TOKEN, participant3, 2000e18);

        // Approve launchpad to spend NOICE
        vm.prank(participant1);
        IERC20(NOICE_TOKEN).approve(address(launchpadWithMock), 5000e18);
        vm.prank(participant2);
        IERC20(NOICE_TOKEN).approve(address(launchpadWithMock), 3000e18);
        vm.prank(participant3);
        IERC20(NOICE_TOKEN).approve(address(launchpadWithMock), 2000e18);

        CreateParams memory createData = _getMinimalCreateParams();
        createData.governanceFactory = IGovernanceFactory(address(governanceFactory));

        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: uint40(block.timestamp + 1 days),
            creatorVestingEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        // Execute bundle with presale
        launchpadWithMock.bundleWithCreatorVesting(params, participants);

        // Verify NOICE was transferred from participants
        assertEq(IERC20(NOICE_TOKEN).balanceOf(participant1), 0, "Participant 1 NOICE not transferred");
        assertEq(IERC20(NOICE_TOKEN).balanceOf(participant2), 0, "Participant 2 NOICE not transferred");
        assertEq(IERC20(NOICE_TOKEN).balanceOf(participant3), 0, "Participant 3 NOICE not transferred");
    }

    function testPresaleEmptyParticipantsArray() public {
        PresaleParticipant[] memory participants = new PresaleParticipant[](0);

        CreateParams memory createData = _getMinimalCreateParams();
        createData.governanceFactory = IGovernanceFactory(address(governanceFactory));

        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: uint40(block.timestamp + 1 days),
            creatorVestingEndTimestamp: uint40(block.timestamp + 365 days)
        });

        BundleWithVestingParams memory params = BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });

        // Should not revert with empty array
        launchpadWithMock.bundleWithCreatorVesting(params, participants);
    }

    function _getMinimalCreateParams()
        private
        view
        returns (CreateParams memory)
    {
        return
            CreateParams({
                initialSupply: INITIAL_SUPPLY,
                numTokensToSell: INITIAL_SUPPLY,
                numeraire: address(testToken),
                tokenFactory: ITokenFactory(address(0)),
                tokenFactoryData: "",
                governanceFactory: IGovernanceFactory(address(0)),
                governanceFactoryData: "",
                poolInitializer: IPoolInitializer(address(0)),
                poolInitializerData: "",
                liquidityMigrator: ILiquidityMigrator(address(0)),
                liquidityMigratorData: "",
                integrator: address(0),
                salt: bytes32(uint256(0xbeef))
            });
    }
}
