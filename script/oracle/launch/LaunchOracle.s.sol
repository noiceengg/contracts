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
 * @title LaunchOracle
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
    address constant LAUNCHPAD = 0xdeeD48775805eEE22600371954dbeA3959Df1Aa5;
    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;

    // Base Mainnet addresses
    address constant NOICE = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;
    address constant TOKEN_FACTORY = 0x4225C632b62622Bd7B0A3eC9745C0a866Ff94F6F;
    address constant LAUNCHPAD_GOVERNANCE_FACTORY = 0x40Bcb4dDA3BcF7dba30C5d10c31EE2791ed9ddCa;
    address constant MULTICURVE_INITIALIZER = 0xA36715dA46Ddf4A769f3290f49AF58bF8132ED8E;
    address constant NOOP_MIGRATOR = 0x6ddfED58D238Ca3195E49d8ac3d4cEa6386E5C33;
    address constant DOPPLER_OWNER = 0x21E2ce70511e4FE542a97708e89520471DAa7A66;
    address constant MULTICURVE_HOOK = 0x3e342a06f9592459D75721d6956B570F02eF2Dc0;

    // Token configuration
    string constant NAME = "Oracle";
    string constant SYMBOL = "ORACLE";
    string constant TOKEN_URI = "ipfs://bafybeia3xdx3otq6fi7l2x5szaz5b6biex747gsyuyqi2tk3lzm66fdaiu";
    uint256 constant INITIAL_SUPPLY = 100_000_000_000 ether; // 100B tokens

    // Token amounts (Total: 100B)
    // NOICE price: $0.0005671
    uint256 constant CREATOR_VESTING = 30_000_000_000 ether; // 30B (30%)
    uint256 constant CREATOR_UNLOCKED = 5_000_000_000 ether; // 5B (5%)
    uint256 constant SSL_TRANCHE_1 = 3_850_000_000 ether; // 3.85B - $252K-$2.5M
    uint256 constant SSL_TRANCHE_2 = 4_460_000_000 ether; // 4.46B - $2.5M-$5M
    uint256 constant SSL_TRANCHE_3 = 4_240_000_000 ether; // 4.24B - $5M-$10M
    uint256 constant SSL_TRANCHE_4 = 2_450_000_000 ether; // 2.45B - $10M-$15M
    uint256 constant PREBUY_LIQUIDITY = 10_000_000_000 ether; // 10B (10% of supply) - $200K-$250K
    uint256 constant PUBLIC_EARLY = 5_000_000_000 ether; // 5B (5% of supply) - $250K-$1M
    uint256 constant PUBLIC_LATE = 35_000_000_000 ether; // 35B (35% of supply) - $1M-$1.5B
    uint256 constant PREBUY_ALLOCATION = 10_000_000_000 ether; // 10B (10% - atomic prebuy)
    uint256 constant NUM_TOKENS_TO_SELL = 50_000_000_000 ether; // 50B (10B prebuy liq + 5B early + 35B late)
    uint256 constant MAX_NOICE_INPUT = 200_000_000 ether; // 200M NOICE max for prebuy

    // Tick boundaries (calculated with NOICE = $0.0005671, 40B tokens in circulation)
    int24 constant TICK_200K = -56460; // $200K (prebuy liquidity start)
    int24 constant TICK_250K = -45060; // $250K (multicurve start)
    int24 constant TICK_2_5M = -22080; // $2.5M
    int24 constant TICK_5M = -15120; // $5M
    int24 constant TICK_10M = -8220; // $10M
    int24 constant TICK_15M = -4140; // $15M
    int24 constant TICK_1M = -31200; // $1M (public late start)
    int24 constant TICK_1_5B = 41940; // $1.5B (multicurve end)

    // SSL tick boundaries (must be above initial tick for token0)
    int24 constant SSL1_TICK_LOWER = -45000; // ~$252K (slightly above $250K start)
    int24 constant SSL1_TICK_UPPER = -22080; // $2.5M
    int24 constant SSL2_TICK_LOWER = -22080; // $2.5M
    int24 constant SSL2_TICK_UPPER = -15120; // $5M
    int24 constant SSL3_TICK_LOWER = -15120; // $5M
    int24 constant SSL3_TICK_UPPER = -8220; // $10M
    int24 constant SSL4_TICK_LOWER = -8220; // $10M
    int24 constant SSL4_TICK_UPPER = -4140; // $15M

    function run() public returns (bytes32, address) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        // Get mined salt from environment (set by MineOracleSalt.s.sol)
        bytes32 salt = vm.envOr("ORACLE_SALT", bytes32(uint256(0)));
        require(salt != bytes32(0), "ORACLE_SALT not set. Run MineOracleSalt.s.sol first");

        console.log("=== Launch Oracle Token ===");
        console.log("NoiceLaunchpad:", LAUNCHPAD);
        console.log("Deployer:", deployer);
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

        vm.startBroadcast(privateKey);

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

        // Multicurve: 3 curves (10B prebuy liquidity + 5B early + 35B late = 50B total)
        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({
            tickLower: TICK_200K,
            tickUpper: TICK_250K,
            numPositions: 1,
            shares: 200000000000000000 // 20% (10B tokens)
        });
        curves[1] = Curve({
            tickLower: TICK_250K,
            tickUpper: TICK_1M,
            numPositions: 20,
            shares: 100000000000000000 // 10% (5B tokens)
        });
        curves[2] = Curve({
            tickLower: TICK_1M,
            tickUpper: TICK_1_5B,
            numPositions: 1,
            shares: 700000000000000000 // 70% (35B tokens)
        });

        // Fee beneficiaries
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({
            beneficiary: DOPPLER_OWNER,
            shares: 50000000000000000 // 5%
        });
        beneficiaries[1] = BeneficiaryData({
            beneficiary: deployer,
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
            integrator: address(0),
            salt: salt
        });

        // Creator allocations: 30B vested + 5B unlocked
        NoiceCreatorAllocation[] memory creatorAllocations = new NoiceCreatorAllocation[](2);
        creatorAllocations[0] = NoiceCreatorAllocation({
            recipient: deployer,
            amount: CREATOR_VESTING,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 730 days)
        });
        creatorAllocations[1] = NoiceCreatorAllocation({
            recipient: deployer,
            amount: CREATOR_UNLOCKED,
            lockStartTimestamp: uint40(block.timestamp),
            lockEndTimestamp: uint40(block.timestamp + 86400)
        });

        // LP unlock tranches
        NoiceLpUnlockTranche[] memory lpUnlockTranches = new NoiceLpUnlockTranche[](4);
        lpUnlockTranches[0] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_1,
            tickLower: SSL1_TICK_LOWER,
            tickUpper: SSL1_TICK_UPPER,
            recipient: deployer
        });
        lpUnlockTranches[1] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_2,
            tickLower: SSL2_TICK_LOWER,
            tickUpper: SSL2_TICK_UPPER,
            recipient: deployer
        });
        lpUnlockTranches[2] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_3,
            tickLower: SSL3_TICK_LOWER,
            tickUpper: SSL3_TICK_UPPER,
            recipient: deployer
        });
        lpUnlockTranches[3] = NoiceLpUnlockTranche({
            amount: SSL_TRANCHE_4,
            tickLower: SSL4_TICK_LOWER,
            tickUpper: SSL4_TICK_UPPER,
            recipient: deployer
        });

        // Build prebuy swap commands (exact output for 10B tokens)
        (bytes memory prebuyCommands, bytes[] memory prebuyInputs) =
            buildPrebuySwap(predictedAsset);

        // Setup prebuy participant (deployer provides NOICE, receives asset tokens)
        NoicePrebuyParticipant[] memory prebuyParticipants = new NoicePrebuyParticipant[](1);
        prebuyParticipants[0] = NoicePrebuyParticipant({
            lockedAddress: deployer,
            noiceAmount: MAX_NOICE_INPUT,
            vestingStartTimestamp: uint40(block.timestamp),
            vestingEndTimestamp: uint40(block.timestamp + 365 days),
            vestingRecipient: deployer
        });

        BundleWithVestingParams memory bundleParams = BundleWithVestingParams({
            createData: createParams,
            noiceCreatorAllocations: creatorAllocations,
            noiceLpUnlockTranches: lpUnlockTranches,
            noicePrebuyCommands: prebuyCommands,
            noicePrebuyInputs: prebuyInputs
        });

        // Approve NOICE for launchpad (for prebuy)
        IERC20(NOICE).approve(LAUNCHPAD, MAX_NOICE_INPUT);

        console.log("Configuration:");
        console.log("- NOICE Price: $0.0005671");
        console.log("- Fee: 2%");
        console.log("- Prebuy Liquidity: 10B (1 position, $200K-$250K)");
        console.log("- Public Early: 5B (20 positions, $250K-$1M)");
        console.log("- Public Late: 35B (single position, $1M-$1.5B)");
        console.log("- Prebuy: 10B (exact output, max 200M NOICE, 1yr vesting)");
        console.log("- SSL1: 3.85B @ $252K-$2.5M");
        console.log("- SSL2: 4.46B @ $2.5M-$5M");
        console.log("- SSL3: 4.24B @ $5M-$10M");
        console.log("- SSL4: 2.45B @ $10M-$15M");
        console.log("- Total SSL: 15B");
        console.log("- Creator: 35B (30B vested 24mo, 5B vested 1d)");
        console.log("- Total multicurve: 50B (10B + 5B + 35B)");
        console.log("");

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

    function buildPrebuySwap(address assetAddress)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
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
        Currency currencyIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency currencyOut = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountOut: uint128(PREBUY_ALLOCATION),
                amountInMaximum: uint128(MAX_NOICE_INPUT),
                hookData: bytes("")
            })
        );
        actionParams[1] = abi.encode(currencyIn, MAX_NOICE_INPUT);
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
