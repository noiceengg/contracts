// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";

contract V4SwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeTransferLib for ERC20;

    IPoolManager public immutable poolManager;

    struct SwapCallbackData {
        PoolKey poolKey;
        IPoolManager.SwapParams swapParams;
        address payer;
        address recipient;
    }

    error CallerNotPoolManager();
    error InsufficientAmountOut();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();
        _;
    }

    function swapExactInput(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address payer,
        address recipient
    ) external returns (uint256 amountOut) {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? 4295128739 : 1461446703485210103287273052203988822378723970342
        });

        SwapCallbackData memory callbackData = SwapCallbackData({
            poolKey: poolKey,
            swapParams: swapParams,
            payer: payer,
            recipient: recipient
        });

        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(callbackData)),
            (BalanceDelta)
        );

        amountOut = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        if (amountOut < amountOutMinimum) revert InsufficientAmountOut();
    }

    function unlockCallback(bytes calldata rawData) external onlyPoolManager returns (bytes memory) {
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(data.poolKey, data.swapParams, "");

        Currency inputCurrency = data.swapParams.zeroForOne ? data.poolKey.currency0 : data.poolKey.currency1;
        Currency outputCurrency = data.swapParams.zeroForOne ? data.poolKey.currency1 : data.poolKey.currency0;

        int256 inputAmount = data.swapParams.zeroForOne ? delta.amount0() : delta.amount1();
        if (inputAmount < 0) {
            _settle(inputCurrency, data.payer, uint256(-inputAmount));
        }

        // Send output tokens from pool manager to recipient
        int256 outputAmount = data.swapParams.zeroForOne ? delta.amount1() : delta.amount0();
        if (outputAmount > 0) {
            _take(outputCurrency, data.recipient, uint256(outputAmount));
        }

        return abi.encode(delta);
    }

    function _settle(Currency currency, address from, uint256 amount) internal {
        if (Currency.unwrap(currency) == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            ERC20(Currency.unwrap(currency)).safeTransferFrom(from, address(this), amount);
            ERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _take(Currency currency, address to, uint256 amount) internal {
        poolManager.take(currency, to, amount);
    }

    function getPoolKey(
        address asset,
        address numeraire,
        address hooks,
        uint24 fee,
        int24 tickSpacing
    ) external pure returns (PoolKey memory) {
        return PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(hooks),
            fee: fee,
            tickSpacing: tickSpacing
        });
    }

    receive() external payable {}
}