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
 * @title LaunchOracle
 * 
 * @notice Launch Oracle token with SSL positions and 10% atomic prebuy
 * @dev Distribution (100B total):
 *      - Creator: 35B (30B vested 24mo, 5B vested 1d)
 *      - Prebuy: 10B (exact output, vested 1yr)
 *      - SSL: 15B (4 tranches)
 *      - Public: 40B (multicurve)
 *
 *      Set ORACLE_SALT env var with salt from MineOracleSalt.s.sol
 *
 *      Run with: forge script script/oracle/launch/LaunchOracle.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract LaunchOracle is Script {
    // NoiceLaunchpad address
    address constant LAUNCHPAD = 0x004bC4469f19FBEc23354fAae0CAE01afb3f4069;

    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;

    // Base Mainnet addresses
    address constant NOICE = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;
    address constant TOKEN_FACTORY = 0x4225C632b62622Bd7B0A3eC9745C0a866Ff94F6F;
    address constant LAUNCHPAD_GOVERNANCE_FACTORY =
        0x004bc4469f19fbec23354faae0cae01afb3f4069;
    address constant MULTICURVE_INITIALIZER =
        0xA36715dA46Ddf4A769f3290f49AF58bF8132ED8E;
    address constant NOOP_MIGRATOR = 0x6ddfED58D238Ca3195E49d8ac3d4cEa6386E5C33;
    address constant DOPPLER_OWNER = 0x21E2ce70511e4FE542a97708e89520471DAa7A66;
    address constant MULTICURVE_HOOK =
        0x3e342a06f9592459D75721d6956B570F02eF2Dc0;

    // Token configuration
    string constant NAME = "oracle";
    string constant SYMBOL = "oracle";
    string constant TOKEN_URI =
        "ipfs://bafkreidmvedswrkgcjojkjqdlqpvwqnxs6mq7eo7nvxjnphi2y6x4bcjae";
    uint256 constant INITIAL_SUPPLY = 100_000_000_000 ether; // 100B tokens

     // NOICE FDV for calculations
    uint256 constant NOICE_FDV = 32_500_000 ether; // $32.5M

    // Token amounts
    uint256 constant CREATOR_VESTING = 25_000_000_000 ether; // 25B (25%)
    uint256 constant CREATOR_UNLOCKED = 5_000_000_000 ether; // 5B (5%)

    // 28 SSL Tranches (20% total = 20B tokens)
    // Tranches 1–3: REMOVE SSL from $1M–$2.2M
    // uint256 constant SSL_TRANCHE_1 = 0;                      // $1.0M–$1.4M
    // uint256 constant SSL_TRANCHE_2 = 0;                      // $1.4M–$1.8M
    // uint256 constant SSL_TRANCHE_3 = 0;                      // $1.8M–$2.2M

    // Total here becomes 6B instead of 4.2B
    uint256 constant SSL_TRANCHE_4 = 857_142_857 ether;      // $2.2M–$2.6M
    uint256 constant SSL_TRANCHE_5 = 857_142_857 ether;      // $2.6M–$3.0M
    uint256 constant SSL_TRANCHE_6 = 857_142_857 ether;      // $3.0M–$3.6M
    uint256 constant SSL_TRANCHE_7 = 857_142_857 ether;      // $3.6M–$4.2M
    uint256 constant SSL_TRANCHE_8 = 857_142_857 ether;      // $4.2M–$4.8M
    uint256 constant SSL_TRANCHE_9 = 857_142_857 ether;      // $4.8M–$5.4M
    uint256 constant SSL_TRANCHE_10 = 857_142_858 ether;     // $5.4M–$6.0M

    // Tranches 11–20: unchanged ($6M–$20M, 15B total across all 1–20)
    uint256 constant SSL_TRANCHE_11 = 800_000_000 ether;     // $6.0M–$7.2M
    uint256 constant SSL_TRANCHE_12 = 800_000_000 ether;     // $7.2M–$8.4M
    uint256 constant SSL_TRANCHE_13 = 800_000_000 ether;     // $8.4M–$9.6M
    uint256 constant SSL_TRANCHE_14 = 800_000_000 ether;     // $9.6M–$10.8M
    uint256 constant SSL_TRANCHE_15 = 800_000_000 ether;     // $10.8M–$12.0M

    uint256 constant SSL_TRANCHE_16 = 1_000_000_000 ether;   // $12.0M–$13.6M
    uint256 constant SSL_TRANCHE_17 = 1_000_000_000 ether;   // $13.6M–$15.2M
    uint256 constant SSL_TRANCHE_18 = 1_000_000_000 ether;   // $15.2M–$16.8M
    uint256 constant SSL_TRANCHE_19 = 1_000_000_000 ether;   // $16.8M–$18.4M
    uint256 constant SSL_TRANCHE_20 = 1_000_000_000 ether;   // $18.4M–$20.0M

    // Tranches 21-28: Additional 5% ($20M-$100M, 5B total)
    uint256 constant SSL_TRANCHE_21 = 625_000_000 ether; // 0.625% - $20M-$30M
    uint256 constant SSL_TRANCHE_22 = 625_000_000 ether; // 0.625% - $30M-$40M
    uint256 constant SSL_TRANCHE_23 = 625_000_000 ether; // 0.625% - $40M-$50M
    uint256 constant SSL_TRANCHE_24 = 625_000_000 ether; // 0.625% - $50M-$60M
    uint256 constant SSL_TRANCHE_25 = 625_000_000 ether; // 0.625% - $60M-$70M
    uint256 constant SSL_TRANCHE_26 = 625_000_000 ether; // 0.625% - $70M-$80M
    uint256 constant SSL_TRANCHE_27 = 625_000_000 ether; // 0.625% - $80M-$90M
    uint256 constant SSL_TRANCHE_28 = 625_000_000 ether; // 0.625% - $90M-$100M

    // Multicurve (50B total = 10B prebuy + 10B curves 1A/1B + 3.75B curves 2A/2B + 26.25B curve 3)
    uint256 constant CURVE_0_TOKENS = 10_000_000_000 ether; // 10B @ $200K-$250K (prebuy)
    uint256 constant CURVE_1A_TOKENS = 4_000_000_000 ether; // 4B @ $250K-$1M
    uint256 constant CURVE_1B_TOKENS = 6_000_000_000 ether; // 6B @ $500K-$1M (overlaps)
    uint256 constant CURVE_2A_TOKENS = 1_875_000_000 ether; // 1.875B @ $1M-$2M
    uint256 constant CURVE_2B_TOKENS = 1_875_000_000 ether; // 1.875B @ $1.5M-$2M (overlaps)
    uint256 constant CURVE_3_TOKENS = 26_250_000_000 ether; // 26.25B @ $2M-$1.5B

    uint256 constant NUM_TOKENS_TO_SELL = 50_000_000_000 ether; // 50B
    uint256 constant PREBUY_ALLOCATION = 10_000_000_000 ether; // 10B (prebuy)

    // Multicurve tick boundaries (user-provided, based on NOICE FDV $34M)
    int24 constant TICK_200K = -51000; // $200K
    int24 constant TICK_250K = -48780; // $250K
    int24 constant TICK_500K = -41820; // $500K
    int24 constant TICK_1M = -34920; // $1M
    int24 constant TICK_1_5M = -30840; // $1.5M
    int24 constant TICK_2M = -27960; // $2M
    int24 constant TICK_1_5B = 38220; // $1.5B

    // SSL Tick Boundaries - 28 tranches (calculated for NOICE FDV $30M)
    int24 constant TICK_1_0M = -34020; // $1.0M
    int24 constant TICK_1_4M = -30660; // $1.4M
    int24 constant TICK_1_8M = -28140; // $1.8M
    int24 constant TICK_2_2M = -26100; // $2.2M
    int24 constant TICK_2_6M = -24480; // $2.6M
    int24 constant TICK_3_0M = -23040; // $3.0M
    int24 constant TICK_3_6M = -21180; // $3.6M
    int24 constant TICK_4_2M = -19680; // $4.2M
    int24 constant TICK_4_8M = -18300; // $4.8M
    int24 constant TICK_5_4M = -17160; // $5.4M
    int24 constant TICK_6_0M = -16080; // $6.0M
    int24 constant TICK_7_2M = -14280; // $7.2M
    int24 constant TICK_8_4M = -12720; // $8.4M
    int24 constant TICK_9_6M = -11400; // $9.6M
    int24 constant TICK_10_8M = -10200; // $10.8M
    int24 constant TICK_12_0M = -9180; // $12.0M
    int24 constant TICK_13_6M = -7920; // $13.6M
    int24 constant TICK_15_2M = -6780; // $15.2M
    int24 constant TICK_16_8M = -5820; // $16.8M
    int24 constant TICK_18_4M = -4860; // $18.4M
    int24 constant TICK_20_0M = -4080; // $20.0M
    int24 constant TICK_30_0M = 0; // $30.0M
    int24 constant TICK_40_0M = 2880; // $40.0M
    int24 constant TICK_50_0M = 5100; // $50.0M
    int24 constant TICK_60_0M = 6960; // $60.0M
    int24 constant TICK_70_0M = 8460; // $70.0M
    int24 constant TICK_80_0M = 9780; // $80.0M
    int24 constant TICK_90_0M = 10980; // $90.0M
    int24 constant TICK_100_0M = 12060; // $100.0M

    // Target swap amount
    uint256 constant TOKENS_TO_SWAP = 50_000_000_000 ether; // 50B tokens
    

    function run() public returns (bytes32, address) {
        address DEPLOYER = 0xe8d333D606d29e89eD4364c1Ee0DE4a694Ad9cD1;
        address FEE_BENEFICIARY = 0xe55b9420e293BB58806b87834C9cC41209b7bc0a;
        address ORACLE_CREATOR = 0x8946A721ddfC85803ab55285Cc2b5259E23bc0ff;
        address ORACLE_SYNDICATE = 0xB0C282B5c64F293F7f4712Ee77318427055e3C3F;
        address ORACLE_ECOSYSTEM = 0x215007a3f0e7517490F9Ba5C7cda4F5b40c64ad5;

        uint40 VESTING_CREATOR_IMMEDIATE_START = 1762878600;
        uint40 VESTING_CREATOR_IMMEDIATE_END = 1762878601;

        uint40 VESTING_CREATOR_VESTED_START = 1765470600;
        uint40 VESTING_CREATOR_VESTED_END = 1797006600;

        uint40 VESTING_ECOSYSTEM_IMMEDIATE_START = 1762878600;
        uint40 VESTING_ECOSYSTEM_IMMEDIATE_END = 1762878601;

        uint40 VESTING_ECOSYSTEM_VESTED_START = 1765470600;
        uint40 VESTING_ECOSYSTEM_VESTED_END = 1797006600;

        uint40 VESTING_SYNDICATE_VESTED_START = 1765470600;
        uint40 VESTING_SYNDICATE_VESTED_END = 1797006600;

        // Get mined salt from environment (set by MineOracleSalt.s.sol)
        bytes32 salt = vm.envOr("ORACLE_SALT", bytes32(uint256(0)));
        require(
            salt != bytes32(0),
            "ORACLE_SALT not set. Run MineOracleSalt.s.sol first"
        );

        console.log("=== Launch Oracle Token ===");

        console.log("FEE_BENEFICIARY:", FEE_BENEFICIARY);
        console.log("ORACLE_CREATOR:", ORACLE_CREATOR);
        console.log("ORACLE_SYNDICATE:", ORACLE_SYNDICATE);
        console.log("ORACLE_ECOSYSTEM:", ORACLE_ECOSYSTEM);
        console.log("NoiceLaunchpad:", LAUNCHPAD);

        console.log("Salt:", vm.toString(salt));

        console.log("");

        // Compute predicted asset address
        address predictedAsset = computeAssetAddress(salt);
        console.log("Predicted asset address:", predictedAsset);

        // Verify address requirements
        require(uint160(predictedAsset) % 0x100 == 0x69, "Address must end in 69");
        require(predictedAsset < NOICE, "Address must be < NOICE");

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

        // Multicurve: 6 curves (50B total)
        Curve[] memory curves = new Curve[](6);

        // Curve 0: 10B @ $200K-$250K (prebuy liquidity) - 20% of 50B
        curves[0] = Curve({
            tickLower: TICK_200K,
            tickUpper: TICK_250K,
            numPositions: 1,
            shares: 200000000000000000 // 20%
        });

        // Curve 1A: 4B @ $250K-$1M - 8% of 50B
        curves[1] = Curve({
            tickLower: TICK_250K,
            tickUpper: TICK_1M,
            numPositions: 10,
            shares: 80000000000000000 // 8%
        });

        // Curve 1B: 6B @ $500K-$1M (overlaps with 1A) - 12% of 50B
        curves[2] = Curve({
            tickLower: TICK_500K,
            tickUpper: TICK_1M,
            numPositions: 5,
            shares: 120000000000000000 // 12%
        });

        // Curve 2A: 1.875B @ $1M-$2M - 3.75% of 50B
        curves[3] = Curve({
            tickLower: TICK_1M,
            tickUpper: TICK_2M,
            numPositions: 5,
            shares: 37500000000000000 // 3.75%
        });

        // Curve 2B: 1.875B @ $1.5M-$2M (overlaps with 2A) - 3.75% of 50B
        curves[4] = Curve({
            tickLower: TICK_1_5M,
            tickUpper: TICK_2M,
            numPositions: 5,
            shares: 37500000000000000 // 3.75%
        });

        // Curve 3: 26.25B @ $2M-$1.5B (late stage) - 52.5% of 50B
        curves[5] = Curve({
            tickLower: TICK_2M,
            tickUpper: TICK_1_5B,
            numPositions: 1,
            shares: 525000000000000000 // 52.5%
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
            numeraire: NOICE,
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

        // Creator allocations: 25B vested 12mo + 5B instant
        NoiceCreatorAllocation[]
            memory creatorAllocations = new NoiceCreatorAllocation[](2);
        creatorAllocations[0] = NoiceCreatorAllocation({
            recipient: ORACLE_CREATOR,
            amount: CREATOR_VESTING,
            lockStartTimestamp: VESTING_CREATOR_VESTED_START,
            lockEndTimestamp: VESTING_CREATOR_VESTED_END
        });
        creatorAllocations[1] = NoiceCreatorAllocation({
            recipient: ORACLE_CREATOR,
            amount: CREATOR_UNLOCKED,
            lockStartTimestamp: VESTING_CREATOR_IMMEDIATE_START,
            lockEndTimestamp: VESTING_CREATOR_IMMEDIATE_END
        });

        // LP unlock tranches - 28 tranches
        NoiceLpUnlockTranche[]
            memory lpUnlockTranches = new NoiceLpUnlockTranche[](25);

        // Tranches 1-20: $1M-$20M
        // lpUnlockTranches[0] = NoiceLpUnlockTranche({
        //     amount: SSL_TRANCHE_1,
        //     tickLower: TICK_1_0M,
        //     tickUpper: TICK_1_4M,
        //     recipient: DEPLOYER
        // });
        // lpUnlockTranches[1] = NoiceLpUnlockTranche({
        //     amount: SSL_TRANCHE_2,
        //     tickLower: TICK_1_4M,
        //     tickUpper: TICK_1_8M,
        //     recipient: DEPLOYER
        // });
        // lpUnlockTranches[2] = NoiceLpUnlockTranche({
        //     amount: SSL_TRANCHE_3,
        //     tickLower: TICK_1_8M,
        //     tickUpper: TICK_2_2M,
        //     recipient: DEPLOYER
        // });
        lpUnlockTranches[0] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_4,
            tickLower: TICK_2_2M,
            tickUpper: TICK_2_6M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[1] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_5,
            tickLower: TICK_2_6M,
            tickUpper: TICK_3_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[2] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_6,
            tickLower: TICK_3_0M,
            tickUpper: TICK_3_6M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[3] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_7,
            tickLower: TICK_3_6M,
            tickUpper: TICK_4_2M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[4] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_8,
            tickLower: TICK_4_2M,
            tickUpper: TICK_4_8M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[5] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_9,
            tickLower: TICK_4_8M,
            tickUpper: TICK_5_4M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[6] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_10,
            tickLower: TICK_5_4M,
            tickUpper: TICK_6_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[7] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_11,
            tickLower: TICK_6_0M,
            tickUpper: TICK_7_2M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[8] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_12,
            tickLower: TICK_7_2M,
            tickUpper: TICK_8_4M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[9] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_13,
            tickLower: TICK_8_4M,
            tickUpper: TICK_9_6M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[10] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_14,
            tickLower: TICK_9_6M,
            tickUpper: TICK_10_8M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[11] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_15,
            tickLower: TICK_10_8M,
            tickUpper: TICK_12_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[12] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_16,
            tickLower: TICK_12_0M,
            tickUpper: TICK_13_6M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[13] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_17,
            tickLower: TICK_13_6M,
            tickUpper: TICK_15_2M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[14] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_18,
            tickLower: TICK_15_2M,
            tickUpper: TICK_16_8M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[15] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_19,
            tickLower: TICK_16_8M,
            tickUpper: TICK_18_4M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[16] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_20,
            tickLower: TICK_18_4M,
            tickUpper: TICK_20_0M,
            recipient: DEPLOYER
        });

        // Tranches 21-28: $20M-$100M
        lpUnlockTranches[17] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_21,
            tickLower: TICK_20_0M,
            tickUpper: TICK_30_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[18] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_22,
            tickLower: TICK_30_0M,
            tickUpper: TICK_40_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[19] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_23,
            tickLower: TICK_40_0M,
            tickUpper: TICK_50_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[20] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_24,
            tickLower: TICK_50_0M,
            tickUpper: TICK_60_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[21] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_25,
            tickLower: TICK_60_0M,
            tickUpper: TICK_70_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[22] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_26,
            tickLower: TICK_70_0M,
            tickUpper: TICK_80_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[23] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_27,
            tickLower: TICK_80_0M,
            tickUpper: TICK_90_0M,
            recipient: DEPLOYER
        });
        lpUnlockTranches[24] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_28,
            tickLower: TICK_90_0M,
            tickUpper: TICK_100_0M,
            recipient: DEPLOYER
        });

        // Build prebuy swap commands (exact output for 10B tokens)
        (
            bytes memory prebuyCommands,
            bytes[] memory prebuyInputs
        ) = buildPrebuySwap(predictedAsset);

        // Setup prebuy participant (deployer provides NOICE, receives asset tokens)

        BundleWithVestingParams memory bundleParams = BundleWithVestingParams({
            createData: createParams,
            noiceCreatorAllocations: creatorAllocations,
            noiceLpUnlockTranches: lpUnlockTranches,
            noicePrebuyCommands: prebuyCommands,
            noicePrebuyInputs: prebuyInputs
        });

        // Prebuy participants (3 participants, 10B total)
        NoicePrebuyParticipant[]
            memory prebuyParticipants = new NoicePrebuyParticipant[](3);

        // Noice Syndicate Fund - Participant 1: 5B vested 365 days
        prebuyParticipants[0] = NoicePrebuyParticipant({
            lockedAddress: ORACLE_SYNDICATE,
            noiceAmount: 45_000_000 ether,
            vestingStartTimestamp: VESTING_SYNDICATE_VESTED_START,
            vestingEndTimestamp: VESTING_SYNDICATE_VESTED_END,
            vestingRecipient: ORACLE_SYNDICATE
        });

        // Noice Ecosystem Fund - Participant 2: 2.5B vested 365 days (same address as participant 1)
        prebuyParticipants[1] = NoicePrebuyParticipant({
            lockedAddress: ORACLE_ECOSYSTEM,
            noiceAmount: 22_500_000 ether,
            vestingStartTimestamp: VESTING_ECOSYSTEM_VESTED_START,
            vestingEndTimestamp: VESTING_ECOSYSTEM_VESTED_END,
            vestingRecipient: ORACLE_ECOSYSTEM
        });

        // Noice Ecosystem Fund - Participant 3: 2.5B instant unlock (1 second vesting)
        prebuyParticipants[2] = NoicePrebuyParticipant({
            lockedAddress: ORACLE_ECOSYSTEM,
            noiceAmount: 22_500_000 ether,
            vestingStartTimestamp: VESTING_ECOSYSTEM_IMMEDIATE_START,
            vestingEndTimestamp: VESTING_ECOSYSTEM_IMMEDIATE_END,
            vestingRecipient: ORACLE_ECOSYSTEM
        });

        console.log("Configuration:");
        console.log("- NOICE FDV: $30M");
        console.log("- NOICE Price: $0.0003");
        console.log("- Fee: 2%");
        console.log("- Multicurve: 6 curves, 50B tokens");
        console.log("  - Curve 0: 10B @ $200K-$250K (20%, prebuy)");
        console.log("  - Curve 1A: 4B @ $250K-$1M (8%)");
        console.log("  - Curve 1B: 6B @ $500K-$1M (12%, overlaps)");
        console.log("  - Curve 2A+2B: 3.75B supply (3.75% each curve)");
        console.log("    - 2A: 1.875B @ $1M-$2M");
        console.log("    - 2B: 1.875B @ $1.5M-$2M (overlaps)");
        console.log("  - Curve 3: 26.25B @ $2M-$1.5B (52.5%)");
        console.log("- Prebuy: 10B (3 participants)");
        console.log("  - Noice Syndicate Fund: 7.5B total (5B + 2.5B vested 365d)");
        console.log("  - Ecosystem Fund: 2.5B instant");
        console.log("- SSL: 28 tranches, 20B tokens total (20%)");
        console.log("  - Tranches 1-20: 15B ($1M-$20M)");
        console.log("  - Tranches 21-28: 5B ($20M-$100M)");
        console.log("- Creator: 30B (25B vested 365d, 5B instant)");
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
        bool isToken0 = assetAddress < NOICE;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(isToken0 ? assetAddress : NOICE),
            currency1: Currency.wrap(isToken0 ? NOICE : assetAddress),
            fee: 20000, // 2%
            tickSpacing: 60,
            hooks: IHooks(MULTICURVE_HOOK)
        });

        // Build V4 swap: NOICE -> Asset (exact output for 10B tokens)
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
