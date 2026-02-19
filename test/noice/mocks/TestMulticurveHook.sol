// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";

/// @notice Thrown when the caller is not authorized
error Unauthorized();

/**
 * @title Test Multicurve Hook
 * @notice Modified hook for testing that allows both initializer AND launchpad to add liquidity
 */
contract TestMulticurveHook is BaseHook {
    /// @notice Address of the Uniswap V4 Multicurve Initializer contract
    address public immutable initializer;

    /// @notice Address of the NumeraireLaunchpad contract
    address public immutable launchpad;

    /// @notice Modifier to ensure the caller is authorized (initializer OR launchpad)
    /// @param sender Address of the caller
    modifier onlyAuthorized(
        address sender
    ) {
        if (sender != initializer && sender != launchpad) revert Unauthorized();
        _;
    }

    /**
     * @notice Constructor for the Test Multicurve Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer_ Address of the Uniswap V4 Multicurve Initializer contract
     * @param launchpad_ Address of the NumeraireLaunchpad contract
     */
    constructor(IPoolManager manager, address initializer_, address launchpad_) BaseHook(manager) {
        initializer = initializer_;
        launchpad = launchpad_;
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view override onlyAuthorized(sender) returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override onlyAuthorized(sender) returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
