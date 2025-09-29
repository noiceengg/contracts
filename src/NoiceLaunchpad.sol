// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { DERC20 } from "src/DERC20.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { ud60x18 } from "prb-math/UD60x18.sol";
import { ISablierLockupMock as ISablierLockup } from "src/interfaces/ISablierLockupMock.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { UniswapV4MulticurveInitializer, InitData } from "src/UniswapV4MulticurveInitializer.sol";

enum ModuleState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    PoolInitializer,
    LiquidityMigrator
}

/// @notice Thrown when the module state is not the expected one
error WrongModuleState(address module, ModuleState expected, ModuleState actual);

/// @notice Thrown when the lengths of two arrays do not match
error ArrayLengthsMismatch();

/// @notice Thrown when presale has too many participants (max 100)
error TooManyPresaleParticipants();

/// @notice Thrown when presale swap fails
error PresaleSwapFailed();

/**
 * @notice Data for a presale participant
 * @param presaleParticipant Address of the participant
 * @param presaleNoiceAmount Amount of quote tokens the participant is contributing
 * @param presaleVestingStartTimestamp When participant's vesting starts
 * @param presaleVestingEndTimestamp When participant's vesting ends
 * @param presaleEscrow Escrow amount for the participant
 */
struct PresaleParticipant {
    address presaleParticipant;
    uint256 presaleNoiceAmount;
    uint256 presaleVestingStartTimestamp;
    uint256 presaleVestingEndTimestamp;
    uint256 presaleEscrow;
}

/**
 * @notice Data related to the asset token
 * @param numeraire Address of the numeraire token
 * @param timelock Address of the timelock contract
 * @param governance Address of the governance contract
 * @param liquidityMigrator Address of the liquidity migrator contract
 * @param poolInitializer Address of the pool initializer contract
 * @param pool Address of the liquidity pool
 * @param migrationPool Address of the liquidity pool after migration
 * @param creatorVestTokenAmount Amount of tokens for creator vesting
 * @param totalSupply Total supply of the token
 * @param integrator Address of the front-end integrator
 * @param creatorVestingStartTimestamp When creator vesting starts for this asset
 * @param creatorVestingEndTimestamp When creator vesting ends for this asset
 * @param quoteToken Address of the quote token used in presale
 * @param presaleParticipantCount Number of presale participants
 */
struct AssetData {
    address numeraire;
    address timelock;
    address governance;
    ILiquidityMigrator liquidityMigrator;
    IPoolInitializer poolInitializer;
    address pool;
    address migrationPool;
    uint256 creatorVestTokenAmount;
    uint256 totalSupply;
    address integrator;
    uint256 creatorVestingStartTimestamp;
    uint256 creatorVestingEndTimestamp;
    address quoteToken;
    uint256 presaleParticipantCount;
}

/**
 * @notice Data used to create a new asset token
 * @param initialSupply Total supply of the token (might be increased later on)
 * @param creatorVestTokenAmount Amount of tokens for creator vesting (up to 50% of supply)
 * @param numeraire Address of the numeraire token
 * @param tokenFactory Address of the factory contract deploying the ERC20 token
 * @param tokenFactoryData Arbitrary data to pass to the token factory
 * @param governanceFactory Address of the factory contract deploying the governance
 * @param governanceFactoryData Arbitrary data to pass to the governance factory
 * @param poolInitializer Address of the pool initializer contract
 * @param poolInitializerData Arbitrary data to pass to the pool initializer
 * @param liquidityMigrator Address of the liquidity migrator contract
 * @param creatorVestingStartTimestamp When creator vesting starts
 * @param creatorVestingEndTimestamp When creator vesting ends
 * @param presaleParticipants Array of presale participants (max 100)
 * @param quoteToken Address of the quote token used in presale
 * @param integrator Address of the front-end integrator
 * @param salt Salt used by the different factories to deploy the contracts using CREATE2
 */
struct CreateParams {
    uint256 initialSupply;
    uint256 creatorVestTokenAmount;
    address numeraire;
    ITokenFactory tokenFactory;
    bytes tokenFactoryData;
    IGovernanceFactory governanceFactory;
    bytes governanceFactoryData;
    IPoolInitializer poolInitializer;
    bytes poolInitializerData;
    ILiquidityMigrator liquidityMigrator;
    bytes liquidityMigratorData;
    uint256 creatorVestingStartTimestamp;
    uint256 creatorVestingEndTimestamp;
    PresaleParticipant[] presaleParticipants;
    address quoteToken;
    address integrator;
    bytes32 salt;
}

/**
 * @notice Emitted when a new asset token is created
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token
 * @param initializer Address of the pool initializer contract, either based on uniswapV3 or uniswapV4
 * @param poolOrHook Address of the liquidity pool (if uniswapV3) or hook (if uniswapV4)
 */
event Create(address asset, address indexed numeraire, address initializer, address poolOrHook);

/**
 * @notice Emitted when an asset token is migrated
 * @param asset Address of the asset token
 * @param pool Address of the liquidity pool
 */
event Migrate(address indexed asset, address indexed pool);

/**
 * @notice Emitted when the state of a module is set
 * @param module Address of the module
 * @param state State of the module
 */
event SetModuleState(address indexed module, ModuleState indexed state);

/**
 * @notice Emitted when fees are collected, either protocol or integrator
 * @param to Address receiving the fees
 * @param token Token from which the fees are collected
 * @param amount Amount of fees collected
 */
event Collect(address indexed to, address indexed token, uint256 amount);

contract NoiceLaunchpad is Ownable, IUnlockCallback {
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(address module => ModuleState state) public getModuleState;
    mapping(address asset => AssetData data) public getAssetData;
    mapping(address token => uint256 amount) public getProtocolFees;
    mapping(address integrator => mapping(address token => uint256 amount)) public getIntegratorFees;

    ISablierLockup public immutable SABLIER_LOCKUP;
    IPoolManager public immutable POOL_MANAGER;

    receive() external payable { }

    /**
     * @param owner_ Address receiving the ownership of the NoiceLaunchPad contract
     * @param poolManager_ Address of the Uniswap V4 PoolManager
     */
    constructor(
        address owner_,
        IPoolManager poolManager_,
        ISablierLockup sablierLockup_
    ) Ownable(owner_) {
        POOL_MANAGER = poolManager_;
        SABLIER_LOCKUP = sablierLockup_;
    }

    /**
     * @notice Deploys a new token with the associated governance, timelock and hook contracts
     * @param createData Data used to create the new token (see `CreateParams` struct)
     * @return asset Address of the deployed asset token
     * @return pool Address of the created liquidity pool
     * @return governance Address of the deployed governance contract
     * @return timelock Address of the deployed timelock contract
     * @return migrationPool Address of the created migration pool
     */
    function create(
        CreateParams calldata createData
    ) external returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        _validateModuleState(address(createData.tokenFactory), ModuleState.TokenFactory);
        _validateModuleState(address(createData.governanceFactory), ModuleState.GovernanceFactory);
        _validateModuleState(address(createData.poolInitializer), ModuleState.PoolInitializer);
        _validateModuleState(address(createData.liquidityMigrator), ModuleState.LiquidityMigrator);

        // Validate presale participants
        if (createData.presaleParticipants.length > 100) {
            revert TooManyPresaleParticipants();
        }

        asset = createData.tokenFactory.create(
            createData.initialSupply, address(this), address(this), createData.salt, createData.tokenFactoryData
        );
        //todo: remove governance
        (governance, timelock) = createData.governanceFactory.create(asset, createData.governanceFactoryData);

        ERC20(asset).approve(address(createData.poolInitializer), createData.creatorVestTokenAmount);
        pool = createData.poolInitializer.initialize(
            asset, createData.numeraire, createData.creatorVestTokenAmount, createData.salt, createData.poolInitializerData
        );
        //todo: remove migration
        migrationPool =
            createData.liquidityMigrator.initialize(asset, createData.numeraire, createData.liquidityMigratorData);
        DERC20(asset).lockPool(migrationPool);

        uint256 excessAsset = ERC20(asset).balanceOf(address(this));

        if (excessAsset > 0) {
            ERC20(asset).approve(address(SABLIER_LOCKUP), excessAsset);

            SABLIER_LOCKUP.createWithTimestampsLL(
                address(this),
                timelock,
                uint128(excessAsset),
                asset,
                true,
                true,
                uint40(createData.creatorVestingStartTimestamp),
                0,
                uint40(createData.creatorVestingEndTimestamp),
                0,
                0
            );
        }

        getAssetData[asset] = AssetData({
            numeraire: createData.numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: createData.liquidityMigrator,
            poolInitializer: createData.poolInitializer,
            pool: pool,
            migrationPool: migrationPool,
            creatorVestTokenAmount: createData.creatorVestTokenAmount,
            totalSupply: createData.initialSupply,
            integrator: createData.integrator == address(0) ? owner() : createData.integrator,
            creatorVestingStartTimestamp: createData.creatorVestingStartTimestamp,
            creatorVestingEndTimestamp: createData.creatorVestingEndTimestamp,
            quoteToken: createData.quoteToken,
            presaleParticipantCount: createData.presaleParticipants.length
        });

        // Execute presale if participants exist
        if (createData.presaleParticipants.length > 0) {
            _executePresale(asset, pool, createData.presaleParticipants, createData.quoteToken, timelock, createData.poolInitializer, createData.poolInitializerData);
        }

        emit Create(asset, createData.numeraire, address(createData.poolInitializer), pool);
    }

    /**
     * @notice Struct to hold swap callback data
     */
    struct SwapCallbackData {
        PoolKey poolKey;
        IPoolManager.SwapParams swapParams;
        address payer;
        address recipient;
    }

    /**
     * @notice Executes a swap using exact input amount
     * @param poolKey The pool key for the swap
     * @param zeroForOne Direction of the swap
     * @param amountIn Amount of input tokens to swap
     * @param amountOutMinimum Minimum amount of output tokens expected
     * @param payer Address that will pay the input tokens
     * @param recipient Address that will receive the output tokens
     * @return amountOut Amount of output tokens received
     */
    function _swapExactInput(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address payer,
        address recipient
    ) internal returns (uint256 amountOut) {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        SwapCallbackData memory callbackData = SwapCallbackData({
            poolKey: poolKey,
            swapParams: swapParams,
            payer: payer,
            recipient: recipient
        });

        bytes memory result = POOL_MANAGER.unlock(abi.encode(callbackData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        amountOut = uint256(int256(-delta.amount1()));

        if (amountOut < amountOutMinimum) {
            revert PresaleSwapFailed();
        }
    }

    /**
     * @notice Callback function for Uniswap V4 unlock
     * @param data Encoded callback data
     * @return bytes Result of the callback
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "Unauthorized callback");

        SwapCallbackData memory callbackData = abi.decode(data, (SwapCallbackData));

        BalanceDelta delta = POOL_MANAGER.swap(callbackData.poolKey, callbackData.swapParams, "");

        // Handle token transfers
        if (delta.amount0() < 0) {
            // Need to pay token0
            Currency currency0 = callbackData.poolKey.currency0;
            POOL_MANAGER.settle();
        }
        if (delta.amount1() < 0) {
            // Need to pay token1
            Currency currency1 = callbackData.poolKey.currency1;
            POOL_MANAGER.settle();
        }

        // Receive tokens
        if (delta.amount0() > 0) {
            Currency currency0 = callbackData.poolKey.currency0;
            POOL_MANAGER.take(currency0, callbackData.recipient, uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            Currency currency1 = callbackData.poolKey.currency1;
            POOL_MANAGER.take(currency1, callbackData.recipient, uint128(delta.amount1()));
        }

        return abi.encode(delta);
    }

    /**
     * @notice Executes presale by buying tokens and distributing to participants
     * @param asset Address of the launched token
     * @param pool Address of the liquidity pool
     * @param participants Array of presale participants
     * @param quoteToken Address of the quote token
     * @param timelock Address of the timelock for governance
     * @param poolInitializer Address of the pool initializer contract
     * @param poolInitializerData Data passed to the pool initializer
     */
    function _executePresale(
        address asset,
        address pool,
        PresaleParticipant[] memory participants,
        address quoteToken,
        address timelock,
        IPoolInitializer poolInitializer,
        bytes memory poolInitializerData
    ) internal {
        if (participants.length > 100) {
            revert TooManyPresaleParticipants();
        }

        // Calculate total presale amount
        uint256 totalPresaleAmount = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            totalPresaleAmount += participants[i].presaleNoiceAmount;
        }

        if (totalPresaleAmount == 0) return;

        for (uint256 i = 0; i < participants.length; i++) {
            ERC20(quoteToken).safeTransferFrom(
                participants[i].presaleParticipant,
                address(this),
                participants[i].presaleNoiceAmount
            );
        }

        bool quoteTokenIsToken0 = quoteToken < asset;

        IHooks hookAddress = UniswapV4MulticurveInitializer(address(poolInitializer)).hook();

        InitData memory initData = abi.decode(poolInitializerData, (InitData));
        uint24 fee = initData.fee;
        int24 tickSpacing = initData.tickSpacing;
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(quoteTokenIsToken0 ? quoteToken : asset),
            currency1: Currency.wrap(quoteTokenIsToken0 ? asset : quoteToken),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hookAddress
        });

        bool zeroForOne = quoteTokenIsToken0;

        uint256 totalTokensReceived = _swapExactInput(
            poolKey,
            zeroForOne,
            totalPresaleAmount,
            0,
            address(this),
            address(this)
        );

        uint256 totalAllocated = 0;

        for (uint256 i = 0; i < participants.length; i++) {
            PresaleParticipant memory participant = participants[i];

            uint256 participantTokens = (participant.presaleNoiceAmount * totalTokensReceived) / totalPresaleAmount;

            if (participantTokens > 0) {
                totalAllocated += participantTokens;

                ERC20(asset).approve(address(SABLIER_LOCKUP), participantTokens);

                SABLIER_LOCKUP.createWithTimestampsLL(
                    address(this),
                    participant.presaleParticipant,
                    uint128(participantTokens),
                    asset,
                    true,
                    true,
                    uint40(participant.presaleVestingStartTimestamp),
                    0,
                    uint40(participant.presaleVestingEndTimestamp),
                    0,
                    0
                );
            }
        }

        require(totalAllocated <= totalTokensReceived, "Over-allocated tokens");

        uint256 remainingTokens = totalTokensReceived - totalAllocated;
        if (remainingTokens > 0 && participants.length > 0) {
            ERC20(asset).transfer(timelock, remainingTokens);
        }
    }

    /**
     * @notice Triggers the migration from the initial liquidity pool to the next one
     * @dev Since anyone can call this function, the conditions for the migration are checked by the
     * `poolInitializer` contract
     * @param asset Address of the token to migrate
     */
    function migrate(
        address asset
    ) external {
        AssetData memory assetData = getAssetData[asset];

        DERC20(asset).unlockPool();
        Ownable(asset).transferOwnership(assetData.timelock);

        (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        ) = assetData.poolInitializer.exitLiquidity(assetData.pool);

        _handleFees(token0, assetData.integrator, balance0, fees0);
        _handleFees(token1, assetData.integrator, balance1, fees1);

        address liquidityMigrator = address(assetData.liquidityMigrator);

        if (token0 == address(0)) {
            SafeTransferLib.safeTransferETH(liquidityMigrator, balance0 - fees0);
        } else {
            ERC20(token0).safeTransfer(liquidityMigrator, balance0 - fees0);
        }

        ERC20(token1).safeTransfer(liquidityMigrator, balance1 - fees1);

        assetData.liquidityMigrator.migrate(sqrtPriceX96, token0, token1, assetData.timelock);

        emit Migrate(asset, assetData.migrationPool);
    }

    /**
     * @dev Computes and stores the protocol and integrators fees. Protocol fees are either 5% of the
     * trading fees or 0.1% of the proceeds (token balance excluding fees) capped at a maximum of 20%
     * of the trading fees
     * @param token Address of the token to handle fees from
     * @param integrator Address of the integrator to handle fees from
     * @param balance Balance of the token including fees
     * @param fees Trading fees
     */
    function _handleFees(address token, address integrator, uint256 balance, uint256 fees) internal {
        if (fees > 0) {
            uint256 protocolLpFees = fees / 20;
            uint256 protocolProceedsFees = (balance - fees) / 1000;
            uint256 protocolFees = Math.max(protocolLpFees, protocolProceedsFees);
            uint256 maxProtocolFees = fees / 5;
            uint256 integratorFees;

            (integratorFees, protocolFees) = protocolFees > maxProtocolFees
                ? (fees - maxProtocolFees, maxProtocolFees)
                : (fees - protocolFees, protocolFees);

            getProtocolFees[token] += protocolFees;
            getIntegratorFees[integrator][token] += integratorFees;
        }
    }

    /**
     * @notice Sets the state of the givens modules
     * @param modules Array of module addresses
     * @param states Array of module states
     */
    function setModuleState(address[] calldata modules, ModuleState[] calldata states) external onlyOwner {
        uint256 length = modules.length;

        if (length != states.length) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i < length; ++i) {
            getModuleState[modules[i]] = states[i];
            emit SetModuleState(modules[i], states[i]);
        }
    }

    /**
     * @notice Collects protocol fees
     * @param to Address receiving the fees
     * @param token Address of the token to collect fees from
     * @param amount Amount of fees to collect
     */
    function collectProtocolFees(address to, address token, uint256 amount) external onlyOwner {
        getProtocolFees[token] -= amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(token).safeTransfer(to, amount);
        }

        emit Collect(to, token, amount);
    }

    /**
     * @notice Collects integrator fees
     * @param to Address receiving the fees
     * @param token Address of the token to collect fees from
     * @param amount Amount of fees to collect
     */
    function collectIntegratorFees(address to, address token, uint256 amount) external {
        getIntegratorFees[msg.sender][token] -= amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(token).safeTransfer(to, amount);
        }

        emit Collect(to, token, amount);
    }

    /**
     * @dev Validates the state of a module
     * @param module Address of the module
     * @param state Expected state of the module
     */
    function _validateModuleState(address module, ModuleState state) internal view {
        require(getModuleState[address(module)] == state, WrongModuleState(module, state, getModuleState[module]));
    }
}
