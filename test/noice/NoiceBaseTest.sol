// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import {
    NumeraireLaunchpad,
    BundleParams,
    NumeraireCreatorAllocation,
    NumeraireLpUnlockTranche,
    PrebuyTranche
} from "src/NoiceLaunchpad.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { ISablierLockup } from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import { ISablierBatchLockup } from "@sablier/v2-core/interfaces/ISablierBatchLockup.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { TeamGovernanceFactory } from "src/TeamGovernanceFactory.sol";
import { DERC20 } from "src/DERC20.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { UniswapV4MulticurveInitializer, InitData } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Position } from "src/types/Position.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { IV4Router } from "@v4-periphery/interfaces/IV4Router.sol";

/**
 * @title NoiceBaseTest
 * @notice Base test contract with common setup and utilities for NumeraireLaunchpad tests
 * @dev All test contracts should inherit from this to avoid code duplication
 * @dev Tests use NOICE as the pool quote token (numeraire) as intended by NumeraireLaunchpad design
 */
abstract contract NoiceBaseTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Core contracts
    NumeraireLaunchpad public launchpad;
    Airlock public airlock;
    ISablierLockup public sablierLockup;
    ISablierBatchLockup public sablierBatchLockup;
    IPoolManager public poolManager;
    UniversalRouter public router;
    TokenFactory public tokenFactory;
    TeamGovernanceFactory public governanceFactory;
    NoOpMigrator public noOpMigrator;
    UniswapV4MulticurveInitializer public multicurveInitializer;
    UniswapV4MulticurveInitializerHook public hook;

    // Test addresses
    address public deployer = makeAddr("deployer");

    // Constants - Base mainnet addresses
    address public constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
    address public constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43; // Uniswap V4 Router
    address public constant SABLIER_LOCKUP = 0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B;
    address public constant SABLIER_BATCH_LOCKUP = 0xC26CdAFd6ec3c91AD9aEeB237Ee1f37205ED26a4;
    address public constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant NOICE_TOKEN = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69; // Quote token (numeraire) for all pools

    // Common test parameters
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000e18; // 100B tokens
    uint256[3] public CURVE_SHARES = [500_000_000_000_000_000, 300_000_000_000_000_000, 200_000_000_000_000_000]; // 50%, 30%, 20%
    int24[3] public TICK_LOWERS = [-20_040, -10_020, 0];
    int24[3] public TICK_UPPERS = [-10_020, 0, 20_040];

    function setUp() public virtual {
        // Fork Base mainnet
        string memory rpcUrl = vm.envString("BASE_MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Initialize external contracts
        airlock = Airlock(payable(AIRLOCK));
        router = UniversalRouter(payable(UNIVERSAL_ROUTER));
        sablierLockup = ISablierLockup(SABLIER_LOCKUP);
        sablierBatchLockup = ISablierBatchLockup(SABLIER_BATCH_LOCKUP);
        poolManager = IPoolManager(POOL_MANAGER);

        // Deploy test contracts
        governanceFactory = new TeamGovernanceFactory();
        tokenFactory = new TokenFactory(address(airlock));
        noOpMigrator = new NoOpMigrator(address(airlock));

        // Calculate hook address with correct permissions
        hook = UniswapV4MulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );

        // Deploy multicurve initializer
        multicurveInitializer = new UniswapV4MulticurveInitializer(address(airlock), poolManager, hook);

        // Deploy hook at calculated address
        deployCodeTo(
            "UniswapV4MulticurveInitializerHook", abi.encode(poolManager, multicurveInitializer), address(hook)
        );

        // Deploy launchpad with test contract as owner (required for role management)
        launchpad = new NumeraireLaunchpad(airlock, router, sablierLockup, sablierBatchLockup, poolManager, address(this));

        // Register modules with Airlock
        _registerAirlockModules();
    }

    /**
     * @notice Register all required modules with Airlock
     */
    function _registerAirlockModules() internal {
        address airlockOwner = airlock.owner();

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(multicurveInitializer);
        modules[3] = address(noOpMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    /**
     * @notice Create default bundle parameters for testing
     * @param noiceCreatorLocks Array of creator lock configurations
     * @return params Bundle parameters with default values
     */
    function _createBundleParams(
        NumeraireCreatorAllocation[] memory noiceCreatorLocks
    ) internal view returns (BundleParams memory params) {
        return _createBundleParams(noiceCreatorLocks, new NumeraireLpUnlockTranche[](0));
    }

    /**
     * @notice Create bundle parameters with LP unlock
     * @dev Configures pool with NOICE as numeraire (quote token)
     * @param noiceCreatorLocks Array of creator lock configurations
     * @param lpUnlockTranches Array of LP unlock tranche configurations
     * @return params Bundle parameters
     */
    function _createBundleParams(
        NumeraireCreatorAllocation[] memory noiceCreatorLocks,
        NumeraireLpUnlockTranche[] memory lpUnlockTranches
    ) internal view virtual returns (BundleParams memory params) {
        // Create curves
        Curve[] memory curves = new Curve[](3);
        for (uint256 i = 0; i < 3; i++) {
            curves[i] = Curve({
                tickLower: TICK_LOWERS[i],
                tickUpper: TICK_UPPERS[i],
                numPositions: 1,
                shares: CURVE_SHARES[i]
            });
        }

        // Setup beneficiaries (airlock owner 5%, deployer 95%)
        address airlockOwner = airlock.owner();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);

        if (airlockOwner < deployer) {
            beneficiaries[0] = BeneficiaryData({
                beneficiary: airlockOwner,
                shares: 50_000_000_000_000_000 // 5%
             });
            beneficiaries[1] = BeneficiaryData({
                beneficiary: deployer,
                shares: 950_000_000_000_000_000 // 95%
             });
        } else {
            beneficiaries[0] = BeneficiaryData({
                beneficiary: deployer,
                shares: 950_000_000_000_000_000 // 95%
             });
            beneficiaries[1] = BeneficiaryData({
                beneficiary: airlockOwner,
                shares: 50_000_000_000_000_000 // 5%
             });
        }

        InitData memory initData =
            InitData({ fee: 3000, tickSpacing: 60, curves: curves, beneficiaries: beneficiaries });

        address[] memory vestRecipients = new address[](0);
        uint256[] memory vestAmounts = new uint256[](0);

        CreateParams memory createData = CreateParams({
            initialSupply: TOTAL_SUPPLY,
            numTokensToSell: TOTAL_SUPPLY,
            numeraire: NOICE_TOKEN,
            tokenFactory: tokenFactory,
            tokenFactoryData: abi.encode("Test Token", "TEST", uint256(0), uint256(0), vestRecipients, vestAmounts, ""),
            governanceFactory: governanceFactory,
            governanceFactoryData: "",
            poolInitializer: multicurveInitializer,
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: noOpMigrator,
            liquidityMigratorData: "",
            integrator: address(0),
            salt: keccak256(abi.encodePacked(block.timestamp, block.number, noiceCreatorLocks.length, lpUnlockTranches.length))
        });

        return BundleParams({
            createData: createData,
            creatorAllocations: noiceCreatorLocks,
            numeraireLpUnlockTranches: lpUnlockTranches,
            prebuyTranches: new PrebuyTranche[](0),
            noicePrebuyCommands: "",
            noicePrebuyInputs: new bytes[](0)
        });
    }

    /**
     * @notice Compute the address of the token that will be created
     * @param salt The salt used in CREATE2
     * @return tokenAddress The predicted token address
     */
    function _computeAssetAddress(
        bytes32 salt
    ) internal view returns (address) {
        return vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        "Test Token",
                        "TEST",
                        TOTAL_SUPPLY,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        ""
                    )
                )
            ),
            address(tokenFactory)
        );
    }

    /**
     * @notice Get the pool key for a launched asset
     * @param asset The asset address
     * @return poolKey The pool key
     */
    function _getPoolKey(
        address asset
    ) internal view returns (PoolKey memory) {
        (,,,, IPoolInitializer poolInitializer,,,,,) = airlock.getAssetData(asset);
        (,, PoolKey memory poolKey,) = UniswapV4MulticurveInitializer(address(poolInitializer)).getState(asset);
        return poolKey;
    }

    /**
     * @notice Query actual liquidity owned by launchpad in a position
     * @param asset The asset address
     * @param position The position struct
     * @return liquidity The actual liquidity amount
     */
    function _getPositionLiquidity(address asset, Position memory position) internal view returns (uint128 liquidity) {
        PoolKey memory poolKey = _getPoolKey(asset);
        (liquidity,,) = poolManager.getPositionInfo(
            poolKey.toId(), address(launchpad), position.tickLower, position.tickUpper, position.salt
        );
    }
}
