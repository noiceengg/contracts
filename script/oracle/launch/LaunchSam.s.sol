// SPDX-License-Identifier: UNLICENSED

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
 * @title LaunchSam
 *
 * @notice Launch SAM token with SSL positions, paired to NOICE
 * @dev Distribution (100B total):
 *      - Creator: 35B (27B vested 6mo, 5B community instant, 3B secondary instant)
 *      - Multicurve: 50B (5B @ $250k-$750k, 45B @ $750k-$1.5B)
 *      - SSL: 15B (9 tranches)
 *
 *      Set ORACLE_SALT env var with salt from MineOracleSalt.s.sol
 *
 *      Run with: forge script script/oracle/launch/LaunchSam.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract LaunchSam is Script {
    // NoiceLaunchpad address
    address constant LAUNCHPAD = 0x004bC4469f19FBEc23354fAae0CAE01afb3f4069;

    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;

    // Base Mainnet addresses
    address constant NOICE = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;
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
    string constant NAME = "SAM";
    string constant SYMBOL = "SAM";
    string constant TOKEN_URI =
        "ipfs://QmULUHxmTj6LgJQ8ouYuJvNEbDqtsgW9HpArwDq82AsRqJ";
    uint256 constant INITIAL_SUPPLY = 100_000_000_000 ether; // 100B tokens

    // Creator allocations (35B total = 35%)
    uint256 constant CREATOR_TEAM_VESTING = 27_000_000_000 ether; // 27% - Team vesting (6mo)
    uint256 constant CREATOR_COMMUNITY = 5_000_000_000 ether; // 5% - Community (instant)
    uint256 constant CREATOR_SECONDARY = 3_000_000_000 ether; // 3% - Secondary markets (instant)

    // Multicurve amounts (50B total = 50% of supply)
    uint256 constant CURVE_0_TOKENS = 5_000_000_000 ether; // 5B @ $250k-$750k (10% of multicurve)
    uint256 constant CURVE_1_TOKENS = 45_000_000_000 ether; // 45B @ $750k-$1.5B (90% of multicurve)

    uint256 constant NUM_TOKENS_TO_SELL = 50_000_000_000 ether; // 50B for public sale

    // SSL tranches (15B total = 15% of supply) - 9 tranches
    // From table: tick ranges are based on FDV with 11.9M NOICE total supply
    uint256 constant SSL_TRANCHE_1 = 928_421_362 ether; // $1M-$2M FDV
    uint256 constant SSL_TRANCHE_2 = 1_055_438_837 ether; // $2M-$3M FDV
    uint256 constant SSL_TRANCHE_3 = 1_182_456_312 ether; // $3M-$4M FDV
    uint256 constant SSL_TRANCHE_4 = 1_309_473_787 ether; // $4M-$5M FDV
    uint256 constant SSL_TRANCHE_5 = 1_436_491_262 ether; // $5M-$6M FDV
    uint256 constant SSL_TRANCHE_6 = 1_563_508_738 ether; // $6M-$7M FDV
    uint256 constant SSL_TRANCHE_7 = 1_690_526_213 ether; // $7M-$8M FDV
    uint256 constant SSL_TRANCHE_8 = 1_817_543_688 ether; // $8M-$9M FDV
    uint256 constant SSL_TRANCHE_9 = 1_944_561_163 ether; // $9M-$10M FDV

    // Multicurve tick boundaries (calculated for NOICE numeraire, 100B supply)
    // NOICE has 18 decimals, total supply 11.9M
    // Ticks calculated for SAM price in NOICE
    int24 constant TICK_250K = -38640; // FDV=$250k
    int24 constant TICK_750K = -27660; // FDV=$750k
    int24 constant TICK_1_5B = 48360; // FDV=$1.5B

    // SSL Tick Boundaries - 9 tranches (from provided table)
    int24 constant TICK_1M = -24780; // FDV=$1M
    int24 constant TICK_2M = -17880; // FDV=$2M
    int24 constant TICK_3M = -13800; // FDV=$3M
    int24 constant TICK_4M = -10920; // FDV=$4M
    int24 constant TICK_5M = -8700; // FDV=$5M
    int24 constant TICK_6M = -6900; // FDV=$6M
    int24 constant TICK_7M = -5340; // FDV=$7M
    int24 constant TICK_8M = -4020; // FDV=$8M
    int24 constant TICK_9M = -2820; // FDV=$9M
    int24 constant TICK_10M = -1740; // FDV=$10M

    function run() public returns (bytes32, address) {
        address DEPLOYER = 0xe8d333D606d29e89eD4364c1Ee0DE4a694Ad9cD1;
        address FEE_BENEFICIARY = 0xEec26bF544509BE429626Fd9F21983ba19d72b5E;
        address TEAM = 0x0e2Ad0B836AD37f762C2E0db02492e71390A0Bf5;
        address SECONDARY = 0x18ccE17c1E825083B38Be03AcDc438a82f8FB1b3;

        // All vesting timestamps (instant = 1 second)
        uint40 INSTANT_START = 1766075400;
        uint40 INSTANT_END = 1766075401;

        // Team vesting (6 months)
        uint40 TEAM_VESTING_START = 1766075400;
        uint40 TEAM_VESTING_END = 1781800200;

        // Get mined salt from environment (set by MineOracleSalt.s.sol)
        bytes32 salt = vm.envOr("ORACLE_SALT", bytes32(uint256(0)));
        require(
            salt != bytes32(0),
            "ORACLE_SALT not set. Run MineOracleSalt.s.sol first"
        );

        console.log("=== Launch SAM Token ===");

        console.log("FEE_BENEFICIARY:", FEE_BENEFICIARY);
        console.log("TEAM:", TEAM);
        console.log("SECONDARY:", SECONDARY);
        console.log("NoiceLaunchpad:", LAUNCHPAD);

        console.log("Salt:", vm.toString(salt));

        console.log("");

        // Compute predicted asset address
        address predictedAsset = computeAssetAddress(salt);
        console.log("Predicted asset address:", predictedAsset);

        // Verify address requirements
        require(
            uint160(predictedAsset) % 0x100 == 0x69,
            "Address must end in 69"
        );
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

        // Multicurve: 2 curves (50B total)
        Curve[] memory curves = new Curve[](2);

        // Curve 0: 5B @ $250K-$750K - 10% of multicurve (5 positions)
        curves[0] = Curve({
            tickLower: TICK_250K,
            tickUpper: TICK_750K,
            numPositions: 5,
            shares: 100000000000000000 // 10%
        });

        // Curve 1: 45B @ $750K-$1.5B - 90% of multicurve (10 positions)
        curves[1] = Curve({
            tickLower: TICK_750K,
            tickUpper: TICK_1_5B,
            numPositions: 10,
            shares: 900000000000000000 // 90%
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

        // Creator allocations: 35B total (27B vested 6mo, 5B instant, 3B instant)
        NoiceCreatorAllocation[]
            memory creatorAllocations = new NoiceCreatorAllocation[](3);

        // Team vesting (27B, 6 months)
        creatorAllocations[0] = NoiceCreatorAllocation({
            recipient: TEAM,
            amount: CREATOR_TEAM_VESTING,
            lockStartTimestamp: TEAM_VESTING_START,
            lockEndTimestamp: TEAM_VESTING_END
        });

        // Community (5B, instant)
        creatorAllocations[1] = NoiceCreatorAllocation({
            recipient: TEAM,
            amount: CREATOR_COMMUNITY,
            lockStartTimestamp: INSTANT_START,
            lockEndTimestamp: INSTANT_END
        });

        // Secondary markets (3B, instant)
        creatorAllocations[2] = NoiceCreatorAllocation({
            recipient: SECONDARY,
            amount: CREATOR_SECONDARY,
            lockStartTimestamp: INSTANT_START,
            lockEndTimestamp: INSTANT_END
        });

        // LP unlock tranches - 9 tranches ($1M-$10M, 15B total)
        NoiceLpUnlockTranche[]
            memory lpUnlockTranches = new NoiceLpUnlockTranche[](9);

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

        // No prebuy for SAM
        BundleWithVestingParams memory bundleParams = BundleWithVestingParams({
            createData: createParams,
            noiceCreatorAllocations: creatorAllocations,
            noiceLpUnlockTranches: lpUnlockTranches,
            noicePrebuyCommands: bytes(""),
            noicePrebuyInputs: new bytes[](0)
        });

        console.log("Configuration:");
        console.log("- Total Supply: 100B tokens");
        console.log("- Numeraire: NOICE (18 decimals)");
        console.log("- Fee: 2%");
        console.log("- Multicurve: 2 curves, 50B tokens (50%)");
        console.log("  - Curve 0: 5B @ $250K-$750K (10%, 5 positions)");
        console.log("  - Curve 1: 45B @ $750K-$1.5B (90%, 10 positions)");
        console.log("- SSL: 9 tranches, 15B tokens total (15%, $1M-$10M)");
        console.log("- Creator: 35B tokens (35%)");
        console.log("  - Team vesting: 27B (6 months)");
        console.log("  - Community: 5B (instant)");
        console.log("  - Secondary: 3B (instant)");
        console.log("");

        // Record logs to capture Create event
        vm.recordLogs();

        // Launch token without prebuy
        launchpad.bundleWithCreatorVesting(
            bundleParams,
            new NoicePrebuyParticipant[](0)
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Launch Complete ===");
        console.log("SAM token:", predictedAsset);
        console.log("");
        console.log("Next: Set TOKEN_ADDRESS=", predictedAsset);
        console.log("Then run misc/sslp/ExecuteTrades.s.sol");

        return (salt, predictedAsset);
    }

    function computeAssetAddress(bytes32 salt) internal view returns (address) {
        return
            vm.computeCreate2Address(
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
