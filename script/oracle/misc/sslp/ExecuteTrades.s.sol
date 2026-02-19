// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";
import {Commands} from "@universal-router/libraries/Commands.sol";
import {Actions} from "@v4-periphery/libraries/Actions.sol";
import {IV4Router} from "@v4-periphery/interfaces/IV4Router.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/**
 * @title ExecuteTrades
 * @notice Execute trades to swap 30B tokens and cross all SSL positions
 * @dev Set TOKEN_ADDRESS env var to the Oracle token address
 *
 *      Run with: forge script script/oracle/misc/sslp/ExecuteTrades.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract ExecuteTrades is Script {
    using PoolIdLibrary for PoolKey;

    // Contract addresses
    address constant NOICE_TOKEN = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant UNIVERSAL_ROUTER =
        0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant MULTICURVE_HOOK =
        0x3e342a06f9592459D75721d6956B570F02eF2Dc0;

    // Target swap amount
    uint256 constant TOKENS_TO_SWAP = 45_000_000_000 ether; // 30B tokens

    PoolKey public poolKey;
    IPoolManager public poolManager;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get token address from environment
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        console2.log("=== Execute Trades to Cross SSL Positions ===");
        console2.log("Deployer:", deployer);
        console2.log("Token (Oracle):", tokenAddress);
        console2.log("NOICE:", NOICE_TOKEN);
        console2.log("");

        poolManager = IPoolManager(POOL_MANAGER);

        // Determine token ordering
        bool isToken0 = tokenAddress < NOICE_TOKEN;

        // Build pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(isToken0 ? tokenAddress : NOICE_TOKEN),
            currency1: Currency.wrap(isToken0 ? NOICE_TOKEN : tokenAddress),
            fee: 20000, // 2%
            tickSpacing: 60,
            hooks: IHooks(MULTICURVE_HOOK)
        });

        PoolId poolId = poolKey.toId();
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console2.log("Token is token0:", isToken0);

        // Get initial pool state
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        console2.log("Initial tick:", vm.toString(currentTick));
        console2.log("");

        // Check NOICE balance
        uint256 noiceBalance = IERC20(NOICE_TOKEN).balanceOf(deployer);
        console2.log("Deployer NOICE balance:", noiceBalance / 1e18);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Approve NOICE to Permit2
        IERC20(NOICE_TOKEN).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            NOICE_TOKEN,
            UNIVERSAL_ROUTER,
            type(uint160).max,
            uint48(block.timestamp + 365 days)
        );
        console2.log("Approved NOICE to Permit2 and Universal Router");
        console2.log("");

        // Execute trade: swap exact output of 30B tokens
        console2.log("--- Executing Swap: Exact Output 30B Tokens ---");

        (uint256 noiceSpent, uint256 tokenReceived) = executeTrade(
            TOKENS_TO_SWAP,
            deployer,
            tokenAddress,
            isToken0
        );

        (, int24 tickAfter, , ) = StateLibrary.getSlot0(poolManager, poolId);
        console2.log("Tick after trade:", vm.toString(tickAfter));
        console2.log("");

        vm.stopBroadcast();

        // Final state
        console2.log("=== Trading Complete ===");
        console2.log("Total NOICE spent:", noiceSpent / 1e18);
        console2.log("Total Token received:", tokenReceived / 1e18);
        console2.log("Final tick:", vm.toString(tickAfter));
        console2.log("");
        console2.log("Next: Run UnlockPositions.s.sol to unlock SSL positions");
    }

    function executeTrade(
        uint256 tokenAmountOut,
        address trader,
        address tokenAddress,
        bool isToken0
    ) internal returns (uint256 noiceSpent, uint256 tokenReceived) {
        // If token is token0: swap NOICE->Token (zeroForOne = false, tick decreases)
        // If token is token1: swap NOICE->Token (zeroForOne = true, tick increases)
        bool zeroForOne = !isToken0;

        // Build V4 router commands for exact output swap
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory actionParams = new bytes[](3);

        // Action 0: SWAP_EXACT_OUT_SINGLE
        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountOut: uint128(tokenAmountOut),
                amountInMaximum: type(uint128).max,
                hookData: bytes("")
            })
        );

        // Action 1: SETTLE_ALL (settle NOICE input)
        Currency currencyIn = isToken0 ? poolKey.currency1 : poolKey.currency0; // NOICE
        actionParams[1] = abi.encode(currencyIn, type(uint128).max);

        // Action 2: TAKE_ALL (take Token output)
        Currency currencyOut = isToken0 ? poolKey.currency0 : poolKey.currency1; // Token
        actionParams[2] = abi.encode(currencyOut, tokenAmountOut);

        // Build Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);

        // Record balances before
        uint256 noiceBefore = IERC20(NOICE_TOKEN).balanceOf(trader);
        uint256 tokenBefore = IERC20(tokenAddress).balanceOf(trader);

        // Execute swap via Universal Router
        UniversalRouter(payable(UNIVERSAL_ROUTER)).execute(
            commands,
            inputs,
            block.timestamp + 365 days
        );

        // Record balances after
        uint256 noiceAfter = IERC20(NOICE_TOKEN).balanceOf(trader);
        uint256 tokenAfter = IERC20(tokenAddress).balanceOf(trader);

        noiceSpent = noiceBefore - noiceAfter;
        tokenReceived = tokenAfter - tokenBefore;

        console2.log("NOICE spent:", noiceSpent / 1e18);
        console2.log("Token received:", tokenReceived / 1e18);
    }
}
