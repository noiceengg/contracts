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
import { ISablierLockup } from "lockup/interfaces/ISablierLockup.sol";
import { Broker, Lockup, LockupLinear } from "lockup/types/DataTypes.sol";
import { V4SwapHelper } from "src/V4SwapHelper.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

enum ModuleState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    PoolInitializer,
    LiquidityMigrator
}

error WrongModuleState(address module, ModuleState expected, ModuleState actual);

error ArrayLengthsMismatch();

struct PresaleParticipant {
    address participantAddress;
    uint256 participantVestingAmount;
    uint256 participantVestingStartTimestamp;
    uint256 participantVestingEndTimestamp;
}

struct AssetData {
    address numeraire;
    address timelock;
    address governance;
    ILiquidityMigrator liquidityMigrator;
    IPoolInitializer poolInitializer;
    address pool;
    address migrationPool;
    uint256 numTokensToSell;
    uint256 totalSupply;
    address integrator;
}

struct CreateParams {
    uint256 initialSupply;
    uint256 numTokensToSell;
    address numeraire;
    ITokenFactory tokenFactory;
    bytes tokenFactoryData;
    IGovernanceFactory governanceFactory;
    bytes governanceFactoryData;
    IPoolInitializer poolInitializer;
    bytes poolInitializerData;
    ILiquidityMigrator liquidityMigrator;
    bytes liquidityMigratorData;
    address integrator;
    bytes32 salt;
    uint256 creatorVestingStartTimestamp;
    uint256 creatorVestingEndTimestamp;
    PresaleParticipant[] presaleParticipants;
}

event Create(address asset, address indexed numeraire, address initializer, address poolOrHook);

event Migrate(address indexed asset, address indexed pool);

event SetModuleState(address indexed module, ModuleState indexed state);

event Collect(address indexed to, address indexed token, uint256 amount);

contract NoiceLaunchpad is Ownable {
    using SafeTransferLib for ERC20;

    mapping(address module => ModuleState state) public getModuleState;
    mapping(address asset => AssetData data) public getAssetData;
    mapping(address token => uint256 amount) public getProtocolFees;
    mapping(address integrator => mapping(address token => uint256 amount)) public getIntegratorFees;

    ISablierLockup public constant SABLIER_LOCKUP = ISablierLockup(0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B);
    V4SwapHelper public immutable SWAP_HELPER;
    uint256 public creatorVestingStartTimestamp;
    uint256 public creatorVestingEndTimestamp;

    receive() external payable { }

    constructor(
        address owner_,
        V4SwapHelper swapHelper_
    ) Ownable(owner_) {
        SWAP_HELPER = swapHelper_;
    }

    function create(
        CreateParams calldata createData
    ) external returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        _validateModuleState(address(createData.tokenFactory), ModuleState.TokenFactory);
        _validateModuleState(address(createData.governanceFactory), ModuleState.GovernanceFactory);
        _validateModuleState(address(createData.poolInitializer), ModuleState.PoolInitializer);
        _validateModuleState(address(createData.liquidityMigrator), ModuleState.LiquidityMigrator);

        creatorVestingStartTimestamp = createData.creatorVestingStartTimestamp;
        creatorVestingEndTimestamp = createData.creatorVestingEndTimestamp;

        asset = createData.tokenFactory.create(
            createData.initialSupply, address(this), address(this), createData.salt, createData.tokenFactoryData
        );

        (governance, timelock) = createData.governanceFactory.create(asset, createData.governanceFactoryData);

        ERC20(asset).approve(address(createData.poolInitializer), createData.numTokensToSell);
        pool = createData.poolInitializer.initialize(
            asset, createData.numeraire, createData.numTokensToSell, createData.salt, createData.poolInitializerData
        );

        migrationPool =
            createData.liquidityMigrator.initialize(asset, createData.numeraire, createData.liquidityMigratorData);
        DERC20(asset).lockPool(migrationPool);

        uint256 excessAsset = ERC20(asset).balanceOf(address(this));

        if (excessAsset > 0) {
            ERC20(asset).approve(address(SABLIER_LOCKUP), excessAsset);

            Lockup.CreateWithTimestamps memory params = Lockup.CreateWithTimestamps({
                sender: address(this),
                recipient: timelock,
                totalAmount: uint128(excessAsset),
                token: IERC20(asset),
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({
                    start: uint40(creatorVestingStartTimestamp),
                    end: uint40(creatorVestingEndTimestamp)
                }),
                shape: "Linear",
                broker: Broker(address(0), ud60x18(0))
            });

            LockupLinear.UnlockAmounts memory unlockAmounts = LockupLinear.UnlockAmounts({
                start: 0,
                cliff: 0
            });

            uint40 cliffTime = 0;

            SABLIER_LOCKUP.createWithTimestampsLL(params, unlockAmounts, cliffTime);
        }

        if (createData.presaleParticipants.length > 0) {
            _handlePresaleParticipants(createData.presaleParticipants, asset, createData.numeraire, pool);
        }

        getAssetData[asset] = AssetData({
            numeraire: createData.numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: createData.liquidityMigrator,
            poolInitializer: createData.poolInitializer,
            pool: pool,
            migrationPool: migrationPool,
            numTokensToSell: createData.numTokensToSell,
            totalSupply: createData.initialSupply,
            integrator: createData.integrator == address(0) ? owner() : createData.integrator
        });

        emit Create(asset, createData.numeraire, address(createData.poolInitializer), pool);
    }

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

    function collectProtocolFees(address to, address token, uint256 amount) external onlyOwner {
        getProtocolFees[token] -= amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(token).safeTransfer(to, amount);
        }

        emit Collect(to, token, amount);
    }

    function collectIntegratorFees(address to, address token, uint256 amount) external {
        getIntegratorFees[msg.sender][token] -= amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(token).safeTransfer(to, amount);
        }

        emit Collect(to, token, amount);
    }

    function _validateModuleState(address module, ModuleState state) internal view {
        require(getModuleState[address(module)] == state, WrongModuleState(module, state, getModuleState[module]));
    }

    function _handlePresaleParticipants(
        PresaleParticipant[] calldata participants,
        address launchedToken,
        address numeraireToken,
        address pool
    ) internal {
        for (uint256 i = 0; i < participants.length; i++) {
            PresaleParticipant calldata participant = participants[i];

            ERC20(numeraireToken).safeTransferFrom(
                participant.participantAddress,
                address(this),
                participant.participantVestingAmount
            );

            uint256 swappedAmount = _swapNumeraireToToken(
                numeraireToken,
                launchedToken,
                participant.participantVestingAmount,
                pool
            );

            ERC20(launchedToken).approve(address(SABLIER_LOCKUP), swappedAmount);

            Lockup.CreateWithTimestamps memory params = Lockup.CreateWithTimestamps({
                sender: address(this),
                recipient: participant.participantAddress,
                totalAmount: uint128(swappedAmount),
                token: IERC20(launchedToken),
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({
                    start: uint40(participant.participantVestingStartTimestamp),
                    end: uint40(participant.participantVestingEndTimestamp)
                }),
                shape: "Linear",
                broker: Broker(address(0), ud60x18(0))
            });

            LockupLinear.UnlockAmounts memory unlockAmounts = LockupLinear.UnlockAmounts({
                start: 0,
                cliff: 0
            });

            uint40 cliffTime = 0;

            SABLIER_LOCKUP.createWithTimestampsLL(params, unlockAmounts, cliffTime);
        }
    }

    function _swapNumeraireToToken(
        address numeraire,
        address token,
        uint256 amountIn,
        address pool
    ) internal returns (uint256 amountOut) {

        PoolKey memory poolKey = SWAP_HELPER.getPoolKey(
            token,
            numeraire,
            pool,
            3000,
            60
        );

        bool zeroForOne = numeraire < token;

        ERC20(numeraire).approve(address(SWAP_HELPER), amountIn);

        uint256 amountOutMinimum = (amountIn * 95) / 100;

        amountOut = SWAP_HELPER.swapExactInput(
            poolKey,
            zeroForOne,
            amountIn,
            amountOutMinimum,
            address(this),
            address(this)
        );

        return amountOut;
    }
}
