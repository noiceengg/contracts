 
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { UniswapV4MulticurveInitializer, InitData } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV4MulticurveMigrator } from "src/UniswapV4MulticurveMigrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { DERC20 } from "src/DERC20.sol";

import { AirlockWithVesting, CreateWithVestingParams } from "src/AirlockWithVesting.sol";
import { MockSablierV2LockupLinear } from "src/vesting/MockSablier.sol";
import { SablierVestingFactory } from "src/vesting/SablierVestingFactory.sol";
import { PresaleBundler, PresaleParticipant } from "src/bundlers/PresaleBundler.sol";

contract LiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract V4WithVestingTest is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    AirlockWithVesting public airlock;
    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public multicurveHook;
    UniswapV4MigratorHook public migratorHook;
    UniswapV4MulticurveMigrator public migrator;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    StreamableFeesLockerV2 public locker;
    LiquidityMigratorMock public mockLiquidityMigrator;
    TestERC20 public numeraire;
    PresaleBundler public bundler;
    MockSablierV2LockupLinear public sablier;
    SablierVestingFactory public vestingFactory;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        numeraire = new TestERC20(1e48);
        vm.label(address(numeraire), "Numeraire");

        airlock = new AirlockWithVesting(airlockOwner);
        bundler = new PresaleBundler(airlock);
        sablier = new MockSablierV2LockupLinear();
        vestingFactory = new SablierVestingFactory(address(sablier));
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        multicurveHook = UniswapV4MulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        initializer = new UniswapV4MulticurveInitializer(address(airlock), manager, multicurveHook);
        migratorHook = UniswapV4MigratorHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        locker = new StreamableFeesLockerV2(manager, airlockOwner);
        migrator = new UniswapV4MulticurveMigrator(address(airlock), manager, migratorHook, locker);
        deployCodeTo("UniswapV4MigratorHook", abi.encode(manager, migrator), address(migratorHook));
        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(manager, initializer), address(multicurveHook));

        mockLiquidityMigrator = new LiquidityMigratorMock();

        address[] memory modules = new address[](5);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);
        modules[4] = address(mockLiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](5);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        states[4] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);
        locker.approveMigrator(address(migrator));
        airlock.setVestingFactory(address(vestingFactory));
        bundler.setVestingFactory(address(vestingFactory));
        vm.stopPrank();
    }

    function _prepareInitData(address token) internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](2);
        int24 tickSpacing = 8;
        curves[0] = Curve({ tickLower: 0, tickUpper: 240_000, numPositions: 4, shares: WAD / 2 });
        curves[1] = Curve({ tickLower: 16_000, tickUpper: 240_000, numPositions: 4, shares: WAD / 2 });

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));
        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({ currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: multicurveHook });
        poolId = poolKey.toId();

        return InitData({ fee: 0, tickSpacing: tickSpacing, curves: curves, beneficiaries: new BeneficiaryData[](0) });
    }

    function test_createWithVesting_allocates_creator_and_presale() public {
        bytes32 salt = bytes32(uint256(0x1234));
        uint256 initialSupply = 1e27;
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 creatorAmt = 1e24;
        uint256 presaleAmt = 2e24;
        uint256 numTokensToSell = initialSupply - creatorAmt - presaleAmt;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(name, symbol, initialSupply, address(airlock), address(airlock), 0, 0, new address[](0), new uint256[](0), "URI")
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitData(tokenAddress);

        address creator = makeAddr("creator");
        uint64 start = uint64(block.timestamp + 1);
        uint64 duration = 30 days;

        vm.recordLogs();
        (address asset,,,,) = airlock.createWithVesting(
            CreateWithVestingParams({
                initialSupply: initialSupply,
                numTokensToSell: numTokensToSell,
                numeraire: address(numeraire),
                tokenFactory: ITokenFactory(tokenFactory),
                tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "URI"),
                governanceFactory: IGovernanceFactory(governanceFactory),
                governanceFactoryData: abi.encode("Gov", 7200, 50_400, 0),
                poolInitializer: IPoolInitializer(initializer),
                poolInitializerData: abi.encode(initData),
                liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
                liquidityMigratorData: new bytes(0),
                integrator: address(0),
                salt: salt,
                creator: creator,
                creatorVestingAmount: creatorAmt,
                creatorVestingStart: start,
                creatorVestingDuration: duration,
                presaleDistributor: address(bundler),
                presaleVestingAmount: presaleAmt
            })
        );

        assertEq(asset, tokenAddress, "asset address mismatch");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vestingAddr;
        uint256 streamId;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == keccak256("CreatorVestingDeployed(address,address,address,uint256)")) {
                (address vesting, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
                vestingAddr = vesting;
                assertEq(amount, creatorAmt, "creator amount");
                break;
            }
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("SablierStreamCreated(address,address,uint256,uint256)")) {
                (uint256 id, ) = abi.decode(logs[i].data, (uint256, uint256));
                streamId = id;
            }
        }
        require(vestingAddr != address(0), "no vesting event");
        assertEq(DERC20(asset).balanceOf(vestingAddr), creatorAmt, "vesting funded");
        assertEq(DERC20(asset).balanceOf(address(bundler)), presaleAmt, "presale reserve");
        vm.warp(start + duration + 1);
        vm.prank(creator);
        sablier.withdraw(streamId, creator);
        assertEq(DERC20(asset).balanceOf(creator), creatorAmt, "creator claimed");
    }

    function test_bundler_launchAndDistribute_distributes_vesting() public {
        bytes32 salt = bytes32(uint256(0x5678));
        uint256 initialSupply = 1e27;
        string memory name = "Test Token";
        string memory symbol = "TEST";
        
        address creator = makeAddr("creator");
        uint256 creatorAmt = 1e24;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(name, symbol, initialSupply, address(airlock), address(airlock), 0, 0, new address[](0), new uint256[](0), "URI")
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitData(tokenAddress);

        uint64 start = uint64(block.timestamp + 1);
        uint64 duration = 15 days;
        
        address a = makeAddr("A");
        address b = makeAddr("B");
        uint256 qa = 1e24;
        uint256 qb = 2e24;
        uint256 price = 5e17;
        
        uint256 presaleAmt = ((qa + qb) * 1e18) / price;
        uint256 numTokensToSell = initialSupply - creatorAmt - presaleAmt;

        numeraire.transfer(a, qa);
        numeraire.transfer(b, qb);
        vm.prank(a); numeraire.approve(address(bundler), type(uint256).max);
        vm.prank(b); numeraire.approve(address(bundler), type(uint256).max);

        PresaleParticipant[] memory parts = new PresaleParticipant[](2);
        parts[0] = PresaleParticipant({ account: a, quoteAmount: qa });
        parts[1] = PresaleParticipant({ account: b, quoteAmount: qb });

        address quoteRecipient = makeAddr("treasury");

        bytes memory poolInitializerData = abi.encode(initData);
        
        vm.recordLogs();
        address asset = bundler.launchAndDistribute(
            CreateWithVestingParams({
                initialSupply: initialSupply,
                numTokensToSell: numTokensToSell,
                numeraire: address(numeraire),
                tokenFactory: ITokenFactory(tokenFactory),
                tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "URI"),
                governanceFactory: IGovernanceFactory(governanceFactory),
                governanceFactoryData: abi.encode("Gov", 7200, 50_400, 0),
                poolInitializer: IPoolInitializer(initializer),
                poolInitializerData: abi.encode(initData),
                liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
                liquidityMigratorData: new bytes(0),
                integrator: address(0),
                salt: salt,
                creator: creator,
                creatorVestingAmount: creatorAmt,
                creatorVestingStart: start,
                creatorVestingDuration: duration,
                presaleDistributor: address(bundler),
                presaleVestingAmount: presaleAmt
            }),
            poolInitializerData,
            parts,
            price,
            start,
            duration,
            quoteRecipient
        );

        assertEq(asset, tokenAddress, "asset address mismatch");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vestA;
        address vestB;
        uint256 streamA;
        uint256 streamB;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("PresaleVestingCreated(address,address,address,uint256)")) {
                address asset_ = address(uint160(uint256(logs[i].topics[1])));
                address beneficiary = address(uint160(uint256(logs[i].topics[2])));
                (address vesting, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
                assertEq(asset_, asset, "asset in event");
                if (beneficiary == a) { vestA = vesting; assertEq(amount, (qa * 1e18) / price, "alloc A"); }
                if (beneficiary == b) { vestB = vesting; assertEq(amount, (qb * 1e18) / price, "alloc B"); }
            }
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("SablierStreamCreated(address,address,uint256,uint256)")) {
                address token_ = address(uint160(uint256(logs[i].topics[1])));
                address beneficiary_ = address(uint160(uint256(logs[i].topics[2])));
                (uint256 id, ) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(token_, asset, "sablier token");
                if (beneficiary_ == a) { streamA = id; }
                if (beneficiary_ == b) { streamB = id; }
            }
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("QuoteForwarded(address,address,uint256)")) {
                address token = address(uint160(uint256(logs[i].topics[1])));
                address recv = address(uint160(uint256(logs[i].topics[2])));
                uint256 amt = abi.decode(logs[i].data, (uint256));
                assertEq(token, address(numeraire), "quote token");
                assertEq(recv, quoteRecipient, "recipient");
                assertEq(amt, qa + qb, "total quote");
            }
        }
        require(vestA != address(0) && vestB != address(0), "vesting addrs");
        vm.warp(start + duration + 1);
        vm.prank(a); sablier.withdraw(streamA, a);
        vm.prank(b); sablier.withdraw(streamB, b);

        uint256 expectedA = (qa * 1e18) / price;
        uint256 expectedB = (qb * 1e18) / price;
        assertEq(DERC20(asset).balanceOf(a), expectedA, "A claimed");
        assertEq(DERC20(asset).balanceOf(b), expectedB, "B claimed");
        assertEq(numeraire.balanceOf(quoteRecipient), qa + qb, "treasury received quote");
    }
}
