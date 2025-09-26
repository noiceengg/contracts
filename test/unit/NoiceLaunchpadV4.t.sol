// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { NoiceLaunchpad, CreateParams, ModuleState, PresaleParticipant } from "src/NoiceLaunchpad.sol";
import { V4SwapHelper } from "src/V4SwapHelper.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";

contract MockV4SwapHelper {
    function swapExactInput(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address payer,
        address recipient
    ) external returns (uint256 amountOut) {
        amountOut = amountIn;
    }

    function getPoolKey(
        address asset,
        address numeraire,
        address hooks,
        uint24 fee,
        int24 tickSpacing
    ) external pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(asset < numeraire ? asset : numeraire),
            currency1: Currency.wrap(asset < numeraire ? numeraire : asset),
            hooks: IHooks(hooks),
            fee: fee,
            tickSpacing: tickSpacing
        });
    }
}

contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply)
        ERC20(name, symbol, 18) {
        _mint(msg.sender, initialSupply);
    }

    function lockPool(address pool) external {
    }
}

contract MockTokenFactory is ITokenFactory {
    function create(
        uint256 initialSupply,
        address initialMinter,
        address initialOwner,
        bytes32 salt,
        bytes calldata data
    ) external returns (address asset) {
        asset = address(new TestERC20("Token", "TKN", initialSupply));
        TestERC20(asset).transfer(initialMinter, initialSupply);
    }
}

contract MockGovernanceFactory is IGovernanceFactory {
    function create(address asset, bytes calldata data) external returns (address governance, address timelock) {
        governance = address(0x1111);
        timelock = address(0x2222);
    }
}

contract MockPoolInitializer is IPoolInitializer {
    function initialize(address asset, address numeraire, uint256 amount, bytes32 salt, bytes calldata data)
        external returns (address pool) {
        pool = address(0x3333);
    }

    function exitLiquidity(address pool) external returns (
        uint160 sqrtPriceX96,
        address token0,
        uint128 fees0,
        uint128 balance0,
        address token1,
        uint128 fees1,
        uint128 balance1
    ) {
        return (0, address(0), 0, 0, address(0), 0, 0);
    }
}

contract MockLiquidityMigrator is ILiquidityMigrator {
    function initialize(address asset, address numeraire, bytes calldata data) external returns (address pool) {
        pool = address(0x4444);
    }

    function migrate(uint160 sqrtPriceX96, address token0, address token1, address recipient) external payable returns (uint256 liquidity) {
        return 0;
    }
}

contract NoiceLaunchpadV4Test is Test {
    NoiceLaunchpad public launchpad;
    MockV4SwapHelper public swapHelper;
    MockTokenFactory public tokenFactory;
    MockGovernanceFactory public governanceFactory;
    MockPoolInitializer public poolInitializer;
    MockLiquidityMigrator public liquidityMigrator;
    TestERC20 public numeraire;

    address public owner;
    address public creator;

    function setUp() public {
        owner = address(0x1000);
        creator = address(0x2000);

        vm.startPrank(owner);

        swapHelper = new MockV4SwapHelper();
        tokenFactory = new MockTokenFactory();
        governanceFactory = new MockGovernanceFactory();
        poolInitializer = new MockPoolInitializer();
        liquidityMigrator = new MockLiquidityMigrator();
        numeraire = new TestERC20("USDC", "USDC", 1_000_000 * 1e6);

        // Deploy launchpad with swapHelper
        launchpad = new NoiceLaunchpad(owner, V4SwapHelper(payable(address(swapHelper))));

        // Set module states
        address[] memory modules = new address[](4);
        ModuleState[] memory states = new ModuleState[](4);

        modules[0] = address(tokenFactory);
        states[0] = ModuleState.TokenFactory;

        modules[1] = address(governanceFactory);
        states[1] = ModuleState.GovernanceFactory;

        modules[2] = address(poolInitializer);
        states[2] = ModuleState.PoolInitializer;

        modules[3] = address(liquidityMigrator);
        states[3] = ModuleState.LiquidityMigrator;

        launchpad.setModuleState(modules, states);

        vm.stopPrank();
    }

    function testV4SwapIntegration() public {
        uint256 initialSupply = 1_000_000 * 1e18;
        uint256 tokensToSell = 500_000 * 1e18;

        PresaleParticipant[] memory participants = new PresaleParticipant[](2);
        participants[0] = PresaleParticipant({
            participantAddress: address(0x5001),
            participantVestingAmount: 10000 * 1e6,
            participantVestingStartTimestamp: block.timestamp + 1 days,
            participantVestingEndTimestamp: block.timestamp + 365 days
        });
        participants[1] = PresaleParticipant({
            participantAddress: address(0x5002),
            participantVestingAmount: 5000 * 1e6,
            participantVestingStartTimestamp: block.timestamp + 7 days,
            participantVestingEndTimestamp: block.timestamp + 180 days
        });

        numeraire.transfer(participants[0].participantAddress, participants[0].participantVestingAmount);
        numeraire.transfer(participants[1].participantAddress, participants[1].participantVestingAmount);

        vm.prank(participants[0].participantAddress);
        numeraire.approve(address(launchpad), participants[0].participantVestingAmount);

        vm.prank(participants[1].participantAddress);
        numeraire.approve(address(launchpad), participants[1].participantVestingAmount);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: tokensToSell,
            numeraire: address(numeraire),
            tokenFactory: tokenFactory,
            tokenFactoryData: "",
            governanceFactory: governanceFactory,
            governanceFactoryData: "",
            poolInitializer: poolInitializer,
            poolInitializerData: "",
            liquidityMigrator: liquidityMigrator,
            liquidityMigratorData: "",
            integrator: address(0),
            salt: bytes32("test"),
            creatorVestingStartTimestamp: block.timestamp + 30 days,
            creatorVestingEndTimestamp: block.timestamp + 395 days,
            presaleParticipants: participants
        });

        vm.prank(owner);
        (address asset, address pool, address governance, address timelock, address migrationPool) = launchpad.create(params);

        assertTrue(asset != address(0));
        assertTrue(pool != address(0));
        assertTrue(governance != address(0));
        assertTrue(timelock != address(0));
        assertTrue(migrationPool != address(0));

        console.log("V4 Swap integration test passed");
        console.log("Asset:", asset);
        console.log("Pool:", pool);
        console.log("Presale participants processed:", participants.length);
    }
}