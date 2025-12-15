// // SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NoiceLaunchpad, BundleWithVestingParams, NoiceCreatorAllocation, NoicePrebuyParticipant, NoiceLpUnlockTranche} from "src/NoiceLaunchpad.sol";
import {Airlock, CreateParams, ITokenFactory, IGovernanceFactory, IPoolInitializer, ILiquidityMigrator} from "src/Airlock.sol";
import {InitData as MulticurveInitData} from "src/UniswapV4MulticurveInitializer.sol";
import {Curve} from "src/libraries/Multicurve.sol";
import {BeneficiaryData} from "src/types/BeneficiaryData.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Commands} from "@universal-router/libraries/Commands.sol";
import {Actions} from "@v4-periphery/libraries/Actions.sol";
import {IV4Router} from "@v4-periphery/interfaces/IV4Router.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {DERC20} from "src/DERC20.sol";

/**
 * @title LaunchRoof
 *
 * @notice Launch Roof token with SSL positions and 10% atomic prebuy
 * @dev Distribution (100M total):
 *      - Creator: 50M (20M vested 6mo, 10M community instant, 8M roof secondary instant, 2M EF instant, 10M roof aero instant)
 *      - Multicurve: 40M (includes 10M prebuy)
 *      - SSL: 10M (14 tranches)
 *
 *      Set ORACLE_SALT env var with salt from MineOracleSalt.s.sol
 *
 *      Run with: forge script script/oracle/launch/LaunchRoof.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract LaunchRoof is Script {
    // NoiceLaunchpad address
    address constant LAUNCHPAD = 0x004bC4469f19FBEc23354fAae0CAE01afb3f4069;

    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;

    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TOKEN_FACTORY = 0x4225C632b62622Bd7B0A3eC9745C0a866Ff94F6F;
    address constant LAUNCHPAD_GOVERNANCE_FACTORY =
        0x40Bcb4dDA3BcF7dba30C5d10c31EE2791ed9ddCa;
    address constant MULTICURVE_INITIALIZER =
        0xA36715dA46Ddf4A769f3290f49AF58bF8132ED8E;
    address constant NOOP_MIGRATOR = 0x6ddfED58D238Ca3195E49d8ac3d4cEa6386E5C33;
    address constant DOPPLER_OWNER = 0x21E2ce70511e4FE542a97708e89520471DAa7A66;
    address constant MULTICURVE_HOOK =
        0x3e342a06f9592459D75721d6956B570F02eF2Dc0;

    // Token configuration
    string constant NAME = "roof";
    string constant SYMBOL = "roof";
    string constant TOKEN_URI =
        "ipfs://bafkreienolrouemvxnpztffgo5ewh6q5km2ohahf5xnljztyi3ii7whixe";
    uint256 constant INITIAL_SUPPLY = 100_000_000 ether; // 100M tokens

    // Creator allocations (50M total = 50%)
    uint256 constant CREATOR_TEAM_VESTING = 20_000_000 ether;    // 20% - Team vesting (6mo)
    uint256 constant CREATOR_COMMUNITY = 10_000_000 ether;       // 10% - Community (instant)
    uint256 constant CREATOR_ROOF_SECONDARY = 8_000_000 ether;   // 8% - Noice Roof secondary (instant)
    uint256 constant CREATOR_NOICE_EF = 2_000_000 ether;         // 2% - Noice EF (instant)
    uint256 constant CREATOR_ROOF_AERO = 10_000_000 ether;       // 10% - Noice Roof aero (instant)

    // Multicurve amounts (40M total = 40% of supply, includes prebuy)
    uint256 constant CURVE_0_TOKENS = 500_000 ether;        // 1.25% of 40M @ 250k-500k
    uint256 constant CURVE_1_TOKENS = 1_064_500 ether;      // 2.66% of 40M @ 500k-750k
    uint256 constant CURVE_2_TOKENS = 8_435_500 ether;      // 21.09% of 40M @ 750k-1m
    uint256 constant CURVE_3_TOKENS = 3_000_000 ether;      // 7.5% of 40M @ 1m-2.5m
    uint256 constant CURVE_4_TOKENS = 4_000_000 ether;      // 10% of 40M @ 1.75m-2.5m
    uint256 constant CURVE_5_TOKENS = 23_000_000 ether;     // 57.5% of 40M @ 2.5m-1.5B (reduced from 33M)

    uint256 constant NUM_TOKENS_TO_SELL = 40_000_000 ether; // 40M for public sale
    uint256 constant PREBUY_ALLOCATION = 10_000_000 ether;  // 10M for atomic prebuy (exact output)
    uint256 constant PREBUY_USDC_AMOUNT = 83_000 * 1e6;     // ~83k USDC for prebuy

    // SSL tranches (10M total = 10% of supply) - 14 tranches from $1M-$15M
    uint256 constant SSL_TRANCHE_1 = 68_027 ether;          // 1M-2M
    uint256 constant SSL_TRANCHE_2 = 136_054 ether;         // 2M-3M
    uint256 constant SSL_TRANCHE_3 = 204_081 ether;         // 3M-4M
    uint256 constant SSL_TRANCHE_4 = 272_108 ether;         // 4M-5M
    uint256 constant SSL_TRANCHE_5 = 340_136 ether;         // 5M-6M
    uint256 constant SSL_TRANCHE_6 = 408_163 ether;         // 6M-7M
    uint256 constant SSL_TRANCHE_7 = 476_190 ether;         // 7M-8M
    uint256 constant SSL_TRANCHE_8 = 544_217 ether;         // 8M-9M
    uint256 constant SSL_TRANCHE_9 = 612_244 ether;         // 9M-10M
    uint256 constant SSL_TRANCHE_10 = 680_272 ether;        // 10M-11M
    uint256 constant SSL_TRANCHE_11 = 748_299 ether;        // 11M-12M
    uint256 constant SSL_TRANCHE_12 = 816_326 ether;        // 12M-13M
    uint256 constant SSL_TRANCHE_13 = 884_353 ether;        // 13M-14M
    uint256 constant SSL_TRANCHE_14 = 952_385 ether;        // 14M-15M

    // Multicurve tick boundaries (calculated for USDC numeraire, 100M supply)
    int24 constant TICK_250K = -337920;  // FDV=$250k, price=$0.0025
    int24 constant TICK_500K = -331020;  // FDV=$500k, price=$0.005
    int24 constant TICK_750K = -327120;  // FDV=$750k, price=$0.0075
    int24 constant TICK_1M = -322260;    // FDV=$1M, price=$0.01
    int24 constant TICK_1_75M = -316500; // FDV=$1.75M, price=$0.0175
    int24 constant TICK_2_5M = -313140;  // FDV=$2.5M, price=$0.025
    int24 constant TICK_1_5B = -221520;  // FDV=$1.5B, price=$15

    // SSL Tick Boundaries - 14 tranches (from provided table, USDC numeraire)
    int24 constant TICK_2M = -311760;   // FDV=$2M
    int24 constant TICK_3M = -304200;   // FDV=$3M
    int24 constant TICK_4M = -298380;   // FDV=$4M
    int24 constant TICK_5M = -293580;   // FDV=$5M
    int24 constant TICK_6M = -289440;   // FDV=$6M
    int24 constant TICK_7M = -285780;   // FDV=$7M
    int24 constant TICK_8M = -282480;   // FDV=$8M
    int24 constant TICK_9M = -279480;   // FDV=$9M
    int24 constant TICK_10M = -276720;  // FDV=$10M
    int24 constant TICK_11M = -274200;  // FDV=$11M
    int24 constant TICK_12M = -271920;  // FDV=$12M
    int24 constant TICK_13M = -269820;  // FDV=$13M
    int24 constant TICK_14M = -267840;  // FDV=$14M
    int24 constant TICK_15M = -265980;  // FDV=$15M
    

    function run() public returns (bytes32, address) {
        address DEPLOYER = 0xe8d333D606d29e89eD4364c1Ee0DE4a694Ad9cD1;
        address FEE_BENEFICIARY = 0xe55b9420e293BB58806b87834C9cC41209b7bc0a;
        address TEAM = 0xAD128d12F7144C1493D76b2D6C9ACE3a92FC0776;
        address ROOF_SECONDARY = 0x5b573A900E3C7D123A1B67701926F3AfAC82303B;
        address NOICE_EF = 0x87152bffd30cFDe89C8c2F55B9d9a49Aa531497F;

        // All vesting timestamps (instant = 1 second)
        uint40 INSTANT_START = 1765816200;
        uint40 INSTANT_END = 1765816201;

        // Team vesting (6 months)
        uint40 TEAM_VESTING_START = 1765816200;
        uint40 TEAM_VESTING_END = 1781541000;

        // Get mined salt from environment (set by MineOracleSalt.s.sol)
        bytes32 salt = vm.envOr("ORACLE_SALT", bytes32(uint256(0)));
        require(
            salt != bytes32(0),
            "ORACLE_SALT not set. Run MineOracleSalt.s.sol first"
        );

        console.log("=== Launch Oracle Token ===");

        console.log("FEE_BENEFICIARY:", FEE_BENEFICIARY);
        console.log("TEAM:", TEAM);
        console.log("ROOF_SECONDARY:", ROOF_SECONDARY);
        console.log("NOICE_EF:", NOICE_EF);
        console.log("NoiceLaunchpad:", LAUNCHPAD);

        console.log("Salt:", vm.toString(salt));

        console.log("");

        // Compute predicted asset address
        address predictedAsset = computeAssetAddress(salt);
        console.log("Predicted asset address:", predictedAsset);

        // Verify address requirements
        require(uint160(predictedAsset) % 0x100 == 0x69, "Address must end in 69");
        require(predictedAsset < USDC, "Address must be < USDC");

        console.log("Address verification passed!");
        console.log("");

        vm.startBroadcast(DEPLOYER);

        NoiceLaunchpad launchpad = NoiceLaunchpad(payable(LAUNCHPAD));

        // Token factory data
        bytes memory tokenFactoryData = abi.encode(
            NAME,
            SYMBOL,
            uint256(0),
            uint256(0),
            new address[](0),
            new uint256[](0),
            TOKEN_URI
        );

        bytes memory governanceFactoryData = abi.encode(address(launchpad));

        // Multicurve: 6 curves (40M total)
        Curve[] memory curves = new Curve[](6);

        // Prebuy curves (250k-1m, 10M total = 25% of 40M)
        // Curve 0: 0.5M @ $250K-$500K - 1.25% of 40M
        curves[0] = Curve({
            tickLower: TICK_250K,
            tickUpper: TICK_500K,
            numPositions: 1,
            shares: 12500000000000000 // 1.25%
        });

        // Curve 1: 1.0645M @ $500K-$750K - 2.66% of 40M
        curves[1] = Curve({
            tickLower: TICK_500K,
            tickUpper: TICK_750K,
            numPositions: 1,
            shares: 26612500000000000 // 2.66125%
        });

        // Curve 2: 8.4355M @ $750K-$1M - 21.09% of 40M
        curves[2] = Curve({
            tickLower: TICK_750K,
            tickUpper: TICK_1M,
            numPositions: 1,
            shares: 210887500000000000 // 21.08875%
        });

        // Public sale curves (1m-2.5m, 7M total = 17.5% of 40M)
        // Curve 3: 3M @ $1M-$2.5M - 7.5% of 40M
        curves[3] = Curve({
            tickLower: TICK_1M,
            tickUpper: TICK_2_5M,
            numPositions: 5,
            shares: 75000000000000000 // 7.5%
        });

        // Curve 4: 4M @ $1.75M-$2.5M (overlaps) - 10% of 40M
        curves[4] = Curve({
            tickLower: TICK_1_75M,
            tickUpper: TICK_2_5M,
            numPositions: 5,
            shares: 100000000000000000 // 10%
        });

        // Constant position curve (2.5m-1.5B, 23M = 57.5% of 40M)
        // Curve 5: 23M @ $2.5M-$1.5B - 57.5% of 40M (reduced from 33M)
        curves[5] = Curve({
            tickLower: TICK_2_5M,
            tickUpper: TICK_1_5B,
            numPositions: 1,
            shares: 575000000000000000 // 57.5%
        });

        // Fee beneficiaries
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: DOPPLER_OWNER,
            shares: 50000000000000000 // 5%
        });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: FEE_BENEFICIARY,
            shares: 950000000000000000 // 95%
        });

        bytes memory poolInitializerData = abi.encode(
            MulticurveInitData({
                fee: uint24(20000), // 2%
                tickSpacing: 60,
                curves: curves,
                beneficiaries: beneficiaries
            })
        );

        CreateParams memory createParams = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: NUM_TOKENS_TO_SELL,
            numeraire: USDC,
            tokenFactory: ITokenFactory(TOKEN_FACTORY),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(LAUNCHPAD_GOVERNANCE_FACTORY),
            governanceFactoryData: governanceFactoryData,
            poolInitializer: IPoolInitializer(MULTICURVE_INITIALIZER),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(NOOP_MIGRATOR),
            liquidityMigratorData: new bytes(0),
            integrator: address(LAUNCHPAD),
            salt: salt
        });

        // Creator allocations: 50M total (20M vested 6mo, 10M instant, 8M instant, 2M instant, 10M instant)
        NoiceCreatorAllocation[]
            memory creatorAllocations = new NoiceCreatorAllocation[](5);

        // Team vesting (20M, 6 months)
        creatorAllocations[0] = NoiceCreatorAllocation({
            recipient: TEAM,
            amount: CREATOR_TEAM_VESTING,
            lockStartTimestamp: TEAM_VESTING_START,
            lockEndTimestamp: TEAM_VESTING_END
        });

        // Community (10M, instant)
        creatorAllocations[1] = NoiceCreatorAllocation({
            recipient: TEAM,
            amount: CREATOR_COMMUNITY,
            lockStartTimestamp: INSTANT_START,
            lockEndTimestamp: INSTANT_END
        });

        // Noice Roof secondary (8M, instant)
        creatorAllocations[2] = NoiceCreatorAllocation({
            recipient: ROOF_SECONDARY,
            amount: CREATOR_ROOF_SECONDARY,
            lockStartTimestamp: INSTANT_START,
            lockEndTimestamp: INSTANT_END
        });

        // Noice EF (2M, instant)
        creatorAllocations[3] = NoiceCreatorAllocation({
            recipient: NOICE_EF,
            amount: CREATOR_NOICE_EF,
            lockStartTimestamp: INSTANT_START,
            lockEndTimestamp: INSTANT_END
        });

        // Noice Roof aero (10M, instant)
        creatorAllocations[4] = NoiceCreatorAllocation({
            recipient: ROOF_SECONDARY,
            amount: CREATOR_ROOF_AERO,
            lockStartTimestamp: INSTANT_START,
            lockEndTimestamp: INSTANT_END
        });

        // LP unlock tranches - 14 tranches ($1M-$15M, 10M total)
        NoiceLpUnlockTranche[]
            memory lpUnlockTranches = new NoiceLpUnlockTranche[](14);

        lpUnlockTranches[0] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_1,
            tickLower: TICK_1M,
            tickUpper: TICK_2M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[1] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_2,
            tickLower: TICK_2M,
            tickUpper: TICK_3M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[2] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_3,
            tickLower: TICK_3M,
            tickUpper: TICK_4M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[3] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_4,
            tickLower: TICK_4M,
            tickUpper: TICK_5M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[4] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_5,
            tickLower: TICK_5M,
            tickUpper: TICK_6M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[5] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_6,
            tickLower: TICK_6M,
            tickUpper: TICK_7M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[6] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_7,
            tickLower: TICK_7M,
            tickUpper: TICK_8M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[7] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_8,
            tickLower: TICK_8M,
            tickUpper: TICK_9M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[8] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_9,
            tickLower: TICK_9M,
            tickUpper: TICK_10M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[9] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_10,
            tickLower: TICK_10M,
            tickUpper: TICK_11M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[10] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_11,
            tickLower: TICK_11M,
            tickUpper: TICK_12M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[11] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_12,
            tickLower: TICK_12M,
            tickUpper: TICK_13M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[12] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_13,
            tickLower: TICK_13M,
            tickUpper: TICK_14M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[13] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_14,
            tickLower: TICK_14M,
            tickUpper: TICK_15M,
            recipient: DEPLOYER
        });

        // Build prebuy swap commands (exact output for 10M tokens)
        (
            bytes memory prebuyCommands,
            bytes[] memory prebuyInputs
        ) = buildPrebuySwap(predictedAsset);

        // Setup prebuy participant (provides USDC, receives asset tokens)
        BundleWithVestingParams memory bundleParams = BundleWithVestingParams({
            createData: createParams,
            noiceCreatorAllocations: creatorAllocations,
            noiceLpUnlockTranches: lpUnlockTranches,
            noicePrebuyCommands: prebuyCommands,
            noicePrebuyInputs: prebuyInputs
        });

        // Prebuy participant: 10M tokens for ~83k USDC, instant unlock
        NoicePrebuyParticipant[]
            memory prebuyParticipants = new NoicePrebuyParticipant[](1);

        prebuyParticipants[0] = NoicePrebuyParticipant({
            lockedAddress: ROOF_SECONDARY,
            noiceAmount: PREBUY_USDC_AMOUNT,
            vestingStartTimestamp: INSTANT_START,
            vestingEndTimestamp: INSTANT_END,
            vestingRecipient: ROOF_SECONDARY
        });

        console.log("Configuration:");
        console.log("- Total Supply: 100M tokens");
        console.log("- Numeraire: USDC (6 decimals)");
        console.log("- Fee: 2%");
        console.log("- Multicurve: 6 curves, 40M tokens (40%)");
        console.log("  - Curve 0: 0.5M @ $250K-$500K (1.25%)");
        console.log("  - Curve 1: 1.06M @ $500K-$750K (2.66%)");
        console.log("  - Curve 2: 8.44M @ $750K-$1M (21.09%)");
        console.log("  - Curve 3: 3M @ $1M-$2.5M (7.5%, 5 positions)");
        console.log("  - Curve 4: 4M @ $1.75M-$2.5M (10%, 5 positions, overlaps)");
        console.log("  - Curve 5: 23M @ $2.5M-$1.5B (57.5%, constant position)");
        console.log("- Prebuy: 10M tokens for 83k USDC (instant unlock)");
        console.log("- SSL: 14 tranches, 10M tokens total (10%, $1M-$15M)");
        console.log("- Creator: 50M tokens (50%)");
        console.log("  - Team vesting: 20M (6 months)");
        console.log("  - Community: 10M (instant)");
        console.log("  - Roof secondary: 8M (instant)");
        console.log("  - Noice EF: 2M (instant)");
        console.log("  - Roof aero: 10M (instant)");
        console.log("");

        // Approve NOICE for launchpad (for prebuy)
        // IERC20(NOICE).approve(address(launchpad), type(uint256).max);

        // Record logs to capture Create event
        vm.recordLogs();

        // Launch token with atomic prebuy
        launchpad.bundleWithCreatorVesting(bundleParams, prebuyParticipants);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Launch Complete ===");
        console.log("Oracle token:", predictedAsset);
        console.log("");
        console.log("Next: Set TOKEN_ADDRESS=", predictedAsset);
        console.log("Then run misc/sslp/ExecuteTrades.s.sol");

        return (salt, predictedAsset);
    }

    function buildPrebuySwap(
        address assetAddress
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        // Determine token ordering
        bool isToken0 = assetAddress < USDC;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(isToken0 ? assetAddress : USDC),
            currency1: Currency.wrap(isToken0 ? USDC : assetAddress),
            fee: 20000, // 2%
            tickSpacing: 60,
            hooks: IHooks(MULTICURVE_HOOK)
        });

        // Build V4 swap: USDC -> Asset (exact output for 10M tokens)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory actionParams = new bytes[](3);
        bool zeroForOne = !isToken0;
        Currency currencyIn = zeroForOne
            ? poolKey.currency0
            : poolKey.currency1;
        Currency currencyOut = zeroForOne
            ? poolKey.currency1
            : poolKey.currency0;

        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountOut: uint128(PREBUY_ALLOCATION),
                amountInMaximum: type(uint128).max,
                hookData: bytes("")
            })
        );
        actionParams[1] = abi.encode(currencyIn, type(uint128).max);
        actionParams[2] = abi.encode(currencyOut, PREBUY_ALLOCATION);

        bytes memory routerInput = abi.encode(actions, actionParams);
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = routerInput;
    }

    function computeAssetAddress(bytes32 salt) internal view returns (address) {
        return vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        NAME,
                        SYMBOL,
                        INITIAL_SUPPLY,
                        AIRLOCK,
                        AIRLOCK,
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        TOKEN_URI
                    )
                )
            ),
            TOKEN_FACTORY
        );
    }
}
