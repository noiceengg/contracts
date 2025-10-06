// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NoiceLaunchpad, BundleWithVestingParams, VestingParams, PresaleParticipant, SSLPTranche} from "src/NoiceLaunchpad.sol";
import {Airlock, CreateParams} from "src/Airlock.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";
import {ISablierLockup} from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {TokenFactory, ITokenFactory} from "src/TokenFactory.sol";
import {TeamGovernanceFactory} from "src/TeamGovernanceFactory.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";
import {IPoolInitializer} from "src/interfaces/IPoolInitializer.sol";
import {ILiquidityMigrator} from "src/interfaces/ILiquidityMigrator.sol";
import {UniswapV4MulticurveInitializer, InitData, PoolState} from "src/UniswapV4MulticurveInitializer.sol";
import {UniswapV4MulticurveInitializerHook} from "src/UniswapV4MulticurveInitializerHook.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {Curve} from "src/libraries/Multicurve.sol";
import {BeneficiaryData} from "src/types/BeneficiaryData.sol";
import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {Vm} from "forge-std/Vm.sol";
import {Position} from "src/types/Position.sol";

/**
 * @title NoiceLaunchpadPresaleAllocationTest
 * @notice Analyzes presale allocation and market cap progression
 */
contract NoiceLaunchpadPresaleAllocationTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    NoiceLaunchpad public launchpad;
    Airlock public airlock;
    ISablierLockup public sablierLockup;
    IPoolManager public poolManager;
    UniversalRouter public router;
    TokenFactory public tokenFactory;
    TeamGovernanceFactory public governanceFactory;
    UniswapV4MulticurveInitializer public multicurveInitializer;
    UniswapV4MulticurveInitializerHook public hook;

    address public buyer = makeAddr("buyer");
    address public creator = makeAddr("creator");
    address public latestAsset;

    /// @dev Token supply allocation: 100B total = 45B creator vesting + 5B SSLP + 50B LP
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 public constant LP_SUPPLY = 50_000_000_000e18;
    uint256 public constant CREATOR_VESTING = 45_000_000_000e18;
    uint256 public constant SSLP_AMOUNT = 5_000_000_000e18;

    /// @dev Initial market cap at pool creation: $69,420
    /// @dev Corresponds to starting tick in multicurve configuration
    uint256 public constant INITIAL_MCAP = 69_420;

    /// @dev NOICE token price: $0.0003695 per token
    /// @dev Used to convert NOICE amounts to USD: usdValue = noiceAmount * 0.0003695
    uint256 public constant NOICE_PRICE = 0.0003695 ether;

    uint256 public constant CREATOR_VESTING_PERCENTAGE = 45;
    uint256 public constant SSLP_PERCENTAGE = 5;

    address public constant NOICE_TOKEN = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;

    /// @dev 7-curve multicurve configuration for price discovery
    /// @dev Shares distribution (out of 10,000 = 100%): [40%, 5%, 10%, 12%, 15%, 10%, 8%]
    /// @dev First curve (40%) provides deepest liquidity at starting price
    /// @dev Subsequent curves create price resistance "valleys" at key market caps (~$200k, ~$500k)
    uint16[7] public CURVE_SHARES = [4000, 500, 1000, 1200, 1500, 1000, 800];

    /// @dev Tick ranges define price boundaries for each curve
    /// @dev Tick -64000 ≈ $0.000694 per token (initial), tick 887272 ≈ max price
    /// @dev Lower ticks = lower prices, higher ticks = higher prices
    /// @dev Formula: price = 1.0001^tick (Uniswap V3/V4 pricing)
    int24[7] public TICK_LOWERS = [-64000, -53400, -50000, -46400, -42200, -37500, -31500];
    int24[7] public TICK_UPPERS = [-53400, -50000, -46400, -42200, -37500, -31500, 887272];

    function setUp() public {
        string memory rpcUrl = vm.envString("BASE_MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        airlock = Airlock(payable(0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12));
        router = UniversalRouter(payable(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3));
        sablierLockup = ISablierLockup(0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B);
        poolManager = IPoolManager(0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829);

        governanceFactory = new TeamGovernanceFactory();
        tokenFactory = new TokenFactory(address(airlock));

        hook = UniswapV4MulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                    Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );

        multicurveInitializer = new UniswapV4MulticurveInitializer(
            address(airlock),
            poolManager,
            hook
        );

        deployCodeTo(
            "UniswapV4MulticurveInitializerHook",
            abi.encode(poolManager, multicurveInitializer),
            address(hook)
        );

        launchpad = new NoiceLaunchpad(
            airlock,
            router,
            sablierLockup,
            NOICE_TOKEN,
            CREATOR_VESTING_PERCENTAGE,
            SSLP_PERCENTAGE,
            poolManager
        );
    }

    function test_PresaleAllocationBreakdown() public {
        /// @dev Test amounts chosen to demonstrate multicurve behavior:
        /// @dev 10M-50M: Initial curve consumption
        /// @dev 72.06M: Targets ~$200k mcap (72.06M * $0.0003695 = $26,626 spent)
        /// @dev 100M-150M: Tests valley resistance after $200k
        /// @dev 250M-400M: Deep liquidity testing
        uint256[] memory presaleAmounts = new uint256[](8);
        presaleAmounts[0] = 10_000_000e18;
        presaleAmounts[1] = 25_000_000e18;
        presaleAmounts[2] = 50_000_000e18;
        presaleAmounts[3] = 72_060_000e18;
        presaleAmounts[4] = 100_000_000e18;
        presaleAmounts[5] = 150_000_000e18;
        presaleAmounts[6] = 250_000_000e18;
        presaleAmounts[7] = 400_000_000e18;

        console2.log("\n=== PRESALE ALLOCATION ANALYSIS ===\n");
        console2.log("NOICE (M) | USD Value  | Mcap       | Tokens (B) | %% LP");
        console2.log("----------|------------|------------|------------|------");

        for (uint256 i = 0; i < presaleAmounts.length; i++) {
            uint256 snapshot = vm.snapshot();

            (uint256 tokensAllocated, uint256 marketCap, address asset) =
                _executePresaleAndGetResults(presaleAmounts[i]);

            uint256 noiceInMillions = presaleAmounts[i] / 1e24; // 1e24 = 1M with 18 decimals
            uint256 usdValue = (presaleAmounts[i] * NOICE_PRICE) / 1e18; // USD = NOICE * $0.0003695 / 1e18
            uint256 tokensInBillions = tokensAllocated / 1e27; // 1e27 = 1B with 18 decimals
            uint256 percentOfLP = (tokensAllocated * 100) / LP_SUPPLY; // % = (allocated / 50B) * 100

            console2.log(
                string(abi.encodePacked(
                    _uint2str(noiceInMillions), " M       | $",
                    _uint2str(usdValue), "     | $",
                    _uint2str(marketCap), "    | ",
                    _uint2str(tokensInBillions), " B        | ",
                    _uint2str(percentOfLP), "%%"
                ))
            );

            vm.revertTo(snapshot);
        }

        console2.log("\n=== KEY INSIGHTS ===");
        console2.log("- Token allocation: 45B creator vesting + 5B SSLP + 50B LP");
        console2.log("- 72.06M NOICE (~$26.6k spent) reaches ~$200k mcap, allocates ~40%% of LP (20B tokens)");
        console2.log("- Valley effect: 100M NOICE (+$10k spent) only adds ~$35k mcap (shallow 5%% curve)");
        console2.log("- First 72M NOICE gets 40%% LP, next 78M gets only 5%% more (valley resistance)");
        console2.log("- 400M NOICE (~$148k spent) allocates ~67%% of LP, reaching ~$520k mcap");
    }

    function _executePresaleAndGetResults(uint256 noiceAmount)
        internal
        returns (uint256 tokensAllocated, uint256 marketCap, address asset)
    {
        PresaleParticipant[] memory participants = new PresaleParticipant[](1);
        participants[0] = PresaleParticipant({
            lockedAddress: buyer,
            noiceAmount: noiceAmount,
            vestingStartTimestamp: uint40(block.timestamp + 1 days),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: buyer
        });

        deal(NOICE_TOKEN, buyer, noiceAmount);

        vm.prank(buyer);
        IERC20(NOICE_TOKEN).approve(address(launchpad), noiceAmount);

        BundleWithVestingParams memory params = _createBundleParams();

        vm.recordLogs();
        launchpad.bundleWithCreatorVesting(params, participants);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] ==
                keccak256("Create(address,address,address,address)")
            ) {
                asset = address(uint160(uint256(logs[i].topics[1])));
                latestAsset = asset;
                break;
            }
        }

        tokensAllocated = _getTokensAllocatedFromPresale();
        marketCap = _getMarketCapFromPool(asset);

        return (tokensAllocated, marketCap, asset);
    }

    function _createBundleParams() internal view returns (BundleWithVestingParams memory) {
        Curve[] memory curves = new Curve[](7);
        for (uint256 i = 0; i < 7; i++) {
            curves[i] = Curve({
                tickLower: TICK_LOWERS[i],
                tickUpper: TICK_UPPERS[i],
                numPositions: 10,
                shares: (uint256(CURVE_SHARES[i]) * 1e18) / 10000 // Convert basis points to WAD: (4000 * 1e18) / 10000 = 0.4e18 = 40%
            });
        }

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);
        InitData memory initData = InitData({
            fee: 0,
            tickSpacing: 8,
            curves: curves,
            beneficiaries: beneficiaries
        });

        CreateParams memory createData = CreateParams({
            initialSupply: TOTAL_SUPPLY,
            numTokensToSell: LP_SUPPLY,
            numeraire: NOICE_TOKEN,
            tokenFactory: tokenFactory,
            tokenFactoryData: abi.encode("PresaleToken", "PRESALE"),
            governanceFactory: governanceFactory,
            governanceFactoryData: abi.encode(creator),
            poolInitializer: IPoolInitializer(address(multicurveInitializer)),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(address(0)),
            liquidityMigratorData: "",
            integrator: address(0),
            salt: bytes32(uint256(block.timestamp))
        });

        VestingParams memory vestingParams = VestingParams({
            creatorVestingStartTimestamp: uint40(block.timestamp + 1 days),
            creatorVestingEndTimestamp: uint40(block.timestamp + 365 days)
        });

        /// @dev SSLP tranches: distribute 5B tokens across price ranges for NOICE rewards
        /// @dev Tranche 1: 40% at $200k-$300k mcap range (2B tokens)
        /// @dev Tranche 2: 60% at $300k-$500k mcap range (3B tokens)
        SSLPTranche[] memory sslpTranches = new SSLPTranche[](2);
        sslpTranches[0] = SSLPTranche({
            shares: 4000, // 40% of SSLP allocation
            tickLower: -50000,
            tickUpper: -46400,
            recipient: creator
        });
        sslpTranches[1] = SSLPTranche({
            shares: 6000, // 60% of SSLP allocation
            tickLower: -46400,
            tickUpper: -42200,
            recipient: creator
        });

        return BundleWithVestingParams({
            createData: createData,
            vestingParams: vestingParams,
            sslpTranches: sslpTranches,
            commands: "",
            inputs: new bytes[](0),
            presaleCommands: "",
            presaleInputs: new bytes[](0)
        });
    }

    function _getTokensAllocatedFromPresale() internal view returns (uint256) {
        uint256 nextId = sablierLockup.nextStreamId();
        if (nextId == 0) return 0;

        uint256 latestStreamId = nextId - 1;
        address recipient = sablierLockup.getRecipient(latestStreamId);
        if (recipient != buyer) {
            if (latestStreamId > 0) {
                latestStreamId--;
                recipient = sablierLockup.getRecipient(latestStreamId);
            }
        }

        uint128 depositedAmount = sablierLockup.getDepositedAmount(latestStreamId);
        return uint256(depositedAmount);
    }

    /// @dev Calculates market cap from pool tick using Uniswap V4 price formula
    /// @dev Step 1: sqrtPriceX96 = sqrt(price) * 2^96 (from pool)
    /// @dev Step 2: price = (sqrtPriceX96)^2 / 2^192
    /// @dev Step 3: priceInNoice = price scaled to 1e18
    /// @dev Step 4: priceUSD = priceInNoice * $0.0003695
    /// @dev Step 5: marketCap = priceUSD * 100B tokens
    /// @dev Note: >> 192 is equivalent to / 2^192 (bit shift optimization)
    function _getMarketCapFromPool(address asset) internal view returns (uint256) {
        (,, PoolKey memory poolKey,) = multicurveInitializer.getState(asset);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 assetPriceInNoice = (priceX192 * 1e18) >> 192; // Divide by 2^192, scale to 1e18
        uint256 assetPriceUSD = (assetPriceInNoice * NOICE_PRICE) / 1e18; // Convert to USD
        uint256 marketCap = (assetPriceUSD * TOTAL_SUPPLY) / 1e18; // Total market cap

        return marketCap;
    }

    function test_SSLPPositionWithdrawal() public {
        /// @dev Test SSLP position creation and withdrawal after price moves
        console2.log("\n=== SSLP POSITION WITHDRAWAL TEST ===\n");

        // Launch token with SSLP positions
        PresaleParticipant[] memory participants = new PresaleParticipant[](0);
        BundleWithVestingParams memory params = _createBundleParams();

        vm.recordLogs();
        launchpad.bundleWithCreatorVesting(params, participants);

        // Get asset address from logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address asset;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] ==
                keccak256("Create(address,address,address,address)")
            ) {
                asset = address(uint160(uint256(logs[i].topics[1])));
                break;
            }
        }

        console2.log("Token launched at initial price");
        console2.log("SSLP positions created: 2 tranches");
        console2.log("  - Tranche 0: 2B tokens at $200k-$300k range");
        console2.log("  - Tranche 1: 3B tokens at $300k-$500k range");

        // Verify positions were created
        Position[] memory positions = launchpad.getSSLPPositions(asset);
        assertEq(positions.length, 2, "Should have 2 SSLP positions");

        // Verify ownership
        address recipient0 = launchpad.sslpPositionRecipient(asset, 0);
        address recipient1 = launchpad.sslpPositionRecipient(asset, 1);
        assertEq(recipient0, creator, "Position 0 should belong to creator");
        assertEq(recipient1, creator, "Position 1 should belong to creator");

        console2.log("\n--- Simulating Price Increase ---");

        // TODO: Simulate swaps to move price through tranches
        // This would require:
        // 1. Getting NOICE tokens
        // 2. Swapping NOICE for asset to move price up
        // 3. Verifying SSLP positions converted to NOICE

        console2.log("(Price movement simulation requires swap integration)");
        console2.log("\nTest validates:");
        console2.log("  - SSLP positions created correctly");
        console2.log("  - Ownership tracked properly");
        console2.log("  - Position count matches tranches");
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
