// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {UniswapV4MulticurveInitializer} from "src/UniswapV4MulticurveInitializer.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {IHooks} from "@v4-core/interfaces/IHooks.sol";

/**
 * @title CollectFees
 * @notice Collect accumulated trading fees from the multicurve positions
 * @dev Set TOKEN_ADDRESS env var to the Oracle token address
 *
 *      Run with: forge script script/oracle/misc/sslp/CollectFees.s.sol \
 *      --rpc-url $BASE_MAINNET_RPC_URL \
 *      --broadcast --private-key $PRIVATE_KEY
 */
contract CollectFees is Script {
    using PoolIdLibrary for PoolKey;

    // Contract addresses
    address constant MULTICURVE_INITIALIZER = 0xA36715dA46Ddf4A769f3290f49AF58bF8132ED8E;
    address constant NOICE_TOKEN = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;
    address constant MULTICURVE_HOOK = 0x3e342a06f9592459D75721d6956B570F02eF2Dc0;

    UniswapV4MulticurveInitializer public initializer;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get token address from environment
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        console2.log("=== Collect Multicurve Fees ===");
        console2.log("Deployer:", deployer);
        console2.log("Token (Oracle):", tokenAddress);
        console2.log("NOICE:", NOICE_TOKEN);
        console2.log("Multicurve Initializer:", MULTICURVE_INITIALIZER);
        console2.log("");

        initializer = UniswapV4MulticurveInitializer(MULTICURVE_INITIALIZER);

        // Check initial balances
        uint256 tokenBefore = IERC20(tokenAddress).balanceOf(deployer);
        uint256 noiceBefore = IERC20(NOICE_TOKEN).balanceOf(deployer);
        console2.log("Initial Token balance:", tokenBefore / 1e18);
        console2.log("Initial NOICE balance:", noiceBefore / 1e18);
        console2.log("");

        // Build pool key
        bool isToken0 = tokenAddress < NOICE_TOKEN;
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(isToken0 ? tokenAddress : NOICE_TOKEN),
            currency1: Currency.wrap(isToken0 ? NOICE_TOKEN : tokenAddress),
            fee: 20000, // 2%
            tickSpacing: 60,
            hooks: IHooks(MULTICURVE_HOOK)
        });

        PoolId poolId = poolKey.toId();
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        console2.log("--- Collecting Fees from Multicurve Positions ---");

        // Collect fees - this will distribute fees to beneficiaries
        (uint128 fees0, uint128 fees1) = initializer.collectFees(poolId);

        console2.log("Fees collected successfully");
        console2.log("Fees0:", fees0 / 1e18);
        console2.log("Fees1:", fees1 / 1e18);
        console2.log("");

        vm.stopBroadcast();

        // Check final balances
        uint256 tokenAfter = IERC20(tokenAddress).balanceOf(deployer);
        uint256 noiceAfter = IERC20(NOICE_TOKEN).balanceOf(deployer);

        console2.log("=== Fee Collection Complete ===");
        console2.log("Final Token balance:", tokenAfter / 1e18);
        console2.log("Final NOICE balance:", noiceAfter / 1e18);
        console2.log("");
        console2.log("Token fees received:", (tokenAfter - tokenBefore) / 1e18);
        console2.log("NOICE fees received:", (noiceAfter - noiceBefore) / 1e18);
        console2.log("");
        console2.log("All SSL operations complete!");
    }
}
