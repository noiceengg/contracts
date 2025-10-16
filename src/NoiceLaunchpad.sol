// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";
import {Airlock, CreateParams, AssetData} from "src/Airlock.sol";
import {IPoolInitializer} from "src/interfaces/IPoolInitializer.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";
import {ISablierLockup} from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import {ISablierBatchLockup} from "@sablier/v2-core/interfaces/ISablierBatchLockup.sol";
import {Lockup, LockupLinear, Broker, BatchLockup} from "@sablier/v2-core/types/DataTypes.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MiniV4Manager} from "src/base/MiniV4Manager.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {Position} from "src/types/Position.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@v4-periphery/libraries/LiquidityAmounts.sol";
import {UniswapV4MulticurveInitializer} from "src/UniswapV4MulticurveInitializer.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@v4-core/types/BalanceDelta.sol";

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/// @notice Thrown when constructor addresses are zero
error InvalidAddresses();

/// @notice Thrown when contract has insufficient token balance
error InsufficientTokenBalance();

/// @notice Thrown when LP unlock tranche configuration is invalid
error InvalidNoiceLpUnlockTranches();

/// @notice Creator allocation configuration
/// @param recipient Address receiving allocated tokens
/// @param amount Amount to allocate
/// @param lockStartTimestamp Vesting start time
/// @param lockEndTimestamp Vesting end time
struct NoiceCreatorAllocation {
    address recipient;
    uint256 amount;
    uint40 lockStartTimestamp;
    uint40 lockEndTimestamp;
}

/// @notice Prebuy participant configuration
/// @dev Participants contribute NOICE (the pool's quote token) to buy launched tokens
/// @param lockedAddress Address holding NOICE tokens
/// @param noiceAmount Amount of NOICE to contribute
/// @param vestingStartTimestamp Vesting start time for received tokens
/// @param vestingEndTimestamp Vesting end time for received tokens
/// @param vestingRecipient Address receiving vested tokens
struct NoicePrebuyParticipant {
    address lockedAddress;
    uint256 noiceAmount;
    uint40 vestingStartTimestamp;
    uint40 vestingEndTimestamp;
    address vestingRecipient;
}

/// @notice LP unlock position configuration
/// @dev Positions accumulate NOICE (the pool's quote token) as trading occurs
/// @param amount Token amount for this tranche
/// @param tickLower Lower tick boundary
/// @param tickUpper Upper tick boundary
/// @param recipient Address that can withdraw accumulated NOICE
struct NoiceLpUnlockTranche {
    uint256 amount;
    int24 tickLower;
    int24 tickUpper;
    address recipient;
}

/// @notice Complete bundle configuration for token launch
/// @param createData Airlock configuration
/// @param noiceCreatorAllocations Array of creator allocations
/// @param noiceLpUnlockTranches LP unlock position configurations (amounts computed from tranches)
/// @param noicePrebuyCommands UniversalRouter commands for NOICE swap
/// @param noicePrebuyInputs UniversalRouter inputs for NOICE swap
struct BundleWithVestingParams {
    CreateParams createData;
    NoiceCreatorAllocation[] noiceCreatorAllocations;
    NoiceLpUnlockTranche[] noiceLpUnlockTranches;
    bytes noicePrebuyCommands;
    bytes[] noicePrebuyInputs;
}

/*

                         ▓▓▓▓
                        ▓▓▓▓▓
                       ▓▓▓▓▓
                       ▓▓▓▓
                      ▓▓▓▓▓                                                            ▓▓▓▓▓▓▓▓
                      ▓▓▓▓▓                                                       ▓▓▓▓▓▓▓▓▓▓▓▓▓
      ▓▓▓▓▓           ▓▓▓▓                                                    ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
     ▓▓▓▓▓▓▓          ▓▓▓▓                      ▓▓▓▓                        ▓▓▓▓▓▓▓▓▓▓▓
     ▓▓▓▓▓▓▓▓         ▓▓▓▓                      ▓▓▓▓▓                     ▓▓▓▓▓▓▓▓
     ▓▓▓▓▓▓▓▓▓        ▓▓▓▓                      ▓▓▓▓▓                     ▓▓▓▓▓
     ▓▓▓▓ ▓▓▓▓▓       ▓▓▓▓                      ▓▓▓▓▓                    ▓▓▓▓▓
     ▓▓▓▓  ▓▓▓▓▓      ▓▓▓▓             ▓▓▓      ▓▓▓▓▓          ▓▓▓       ▓▓▓▓   ▓▓▓▓▓▓▓▓▓
     ▓▓▓▓   ▓▓▓▓      ▓▓▓▓▓      ▓▓▓▓▓▓▓▓▓▓▓    ▓▓▓▓▓     ▓▓▓▓▓▓▓▓▓▓▓▓   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
     ▓▓▓▓   ▓▓▓▓▓     ▓▓▓▓▓    ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓
     ▓▓▓▓    ▓▓▓▓▓    ▓▓▓▓▓   ▓▓▓▓▓      ▓▓▓▓▓▓ ▓▓▓▓▓  ▓▓▓▓▓▓           ▓▓▓▓▓▓
     ▓▓▓▓     ▓▓▓▓▓    ▓▓▓▓  ▓▓▓▓▓        ▓▓▓▓▓  ▓▓▓▓  ▓▓▓▓             ▓▓▓▓▓
     ▓▓▓▓      ▓▓▓▓▓   ▓▓▓▓  ▓▓▓▓          ▓▓▓▓  ▓▓▓▓  ▓▓▓▓             ▓▓▓▓▓
     ▓▓▓▓▓      ▓▓▓▓▓  ▓▓▓▓  ▓▓▓▓         ▓▓▓▓▓  ▓▓▓▓  ▓▓▓▓▓             ▓▓▓▓
      ▓▓▓▓       ▓▓▓▓  ▓▓▓▓  ▓▓▓▓▓▓      ▓▓▓▓▓▓  ▓▓▓▓  ▓▓▓▓▓▓▓    ▓▓▓▓▓  ▓▓▓▓▓▓
      ▓▓▓▓       ▓▓▓▓▓ ▓▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓     ▓▓▓▓   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
      ▓▓▓▓        ▓▓▓▓▓▓▓▓▓▓    ▓▓▓▓▓▓▓▓▓▓▓       ▓▓▓▓    ▓▓▓▓▓▓▓▓▓▓▓      ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
      ▓▓▓▓         ▓▓▓▓▓▓▓▓        ▓▓▓▓▓          ▓▓▓                              ▓▓▓▓▓▓▓▓
                     ▓▓▓▓▓

*/

/**
 * @title NoiceLaunchpad
 * @notice Atomic token launch with creator vesting, LP unlock positions, and prebuy allocation
 * @dev Designed for NOICE as the quote token (pool numeraire), though not enforced at contract level
 * @dev All prebuy participants contribute NOICE, and LP unlock positions accumulate NOICE
 *
 * Launch Flow:
 *
 *    ┌─────────────────────────────────────────┐
 *    │  1. Create token + Doppler multicurve   │
 *    │     uni v4 pool (NOICE as numeraire)        │
 *    └──────────────────┬──────────────────────┘
 *                       │
 *                       ▼
 *    ┌─────────────────────────────────────────┐
 *    │  2. Allocate tokens to create           │
 *    │     NOICE LP unlock positions           │
 *    │     (out-of-range, unlocks NOICE when   |
      |            tick range is crossed)       │
 *    └──────────────────┬──────────────────────┘
 *                       │
 *                       ▼
 *    ┌─────────────────────────────────────────┐
 *    │  3. Allocate tokens for creator         │
 *    │     allocations (with vesting)          │
 *    └──────────────────┬──────────────────────┘
 *                       │
 *                       ▼
 *    ┌─────────────────────────────────────────┐
 *    │  4. Allocate tokens for prebuy:         │
 *    │     NOICE → Asset (swap & vesting)      │
 *    └─────────────────────────────────────────┘
 */
contract NoiceLaunchpad is MiniV4Manager, OwnableRoles {
    using SafeTransferLib for address;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    Airlock public immutable AIRLOCK;
    UniversalRouter public immutable ROUTER;
    ISablierLockup public immutable SABLIER_LOCKUP;
    ISablierBatchLockup public immutable SABLIER_BATCH_LOCKUP;
    IPermit2 private constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @notice Role for executing bundle and withdraw operations
    uint256 public constant EXECUTOR_ROLE = _ROLE_0;

    mapping(address asset => Position[] positions)
        public noiceLpUnlockPositions;
    mapping(address asset => mapping(uint256 positionIndex => address recipient))
        public noiceLpUnlockPositionRecipient;
    mapping(address asset => mapping(uint256 positionIndex => bool withdrawn))
        public noiceLpUnlockPositionWithdrawn;

    constructor(
        Airlock airlock_,
        UniversalRouter router_,
        ISablierLockup sablierLockup_,
        ISablierBatchLockup sablierBatchLockup_,
        IPoolManager poolManager_,
        address owner_
    ) MiniV4Manager(poolManager_) {
        if (
            address(airlock_) == address(0) ||
            address(router_) == address(0) ||
            address(sablierLockup_) == address(0) ||
            address(sablierBatchLockup_) == address(0) ||
            address(poolManager_) == address(0) ||
            owner_ == address(0)
        ) {
            revert InvalidAddresses();
        }

        AIRLOCK = airlock_;
        ROUTER = router_;
        SABLIER_LOCKUP = sablierLockup_;
        SABLIER_BATCH_LOCKUP = sablierBatchLockup_;
        _initializeOwner(owner_);
    }

    /// @notice Main entry point for atomic token launch
    /// @dev Executes in order: validation → token creation → LP unlock → creator vesting → prebuy → refund
    /// @dev Callable by addresses with EXECUTOR_ROLE or owner
    /// @param params Complete bundle configuration
    /// @param noicePrebuyParticipants Array of prebuy participants
    function bundleWithCreatorVesting(
        BundleWithVestingParams calldata params,
        NoicePrebuyParticipant[] calldata noicePrebuyParticipants
    ) external payable onlyRolesOrOwner(EXECUTOR_ROLE) {
        uint256 totalCreatorAllocationAmount = 0;
        for (uint256 i = 0; i < params.noiceCreatorAllocations.length; i++) {
            totalCreatorAllocationAmount += params
                .noiceCreatorAllocations[i]
                .amount;
        }

        // Compute LP unlock amount from tranches
        uint256 noiceLpUnlockAmount = 0;
        for (uint256 i = 0; i < params.noiceLpUnlockTranches.length; i++) {
            noiceLpUnlockAmount += params.noiceLpUnlockTranches[i].amount;
        }

        CreateParams memory createData = params.createData;
        // Solidity 0.8+ will automatically revert on underflow if allocations exceed supply
        createData.numTokensToSell =
            params.createData.initialSupply -
            totalCreatorAllocationAmount -
            noiceLpUnlockAmount;

        createData.governanceFactoryData = abi.encode(address(this));

        (address asset, , , , ) = AIRLOCK.create(createData);

        if (
            noiceLpUnlockAmount > 0 && params.noiceLpUnlockTranches.length > 0
        ) {
            _createNoiceLpUnlockPositions(
                asset,
                noiceLpUnlockAmount,
                params.noiceLpUnlockTranches
            );
        }

        if (params.noiceCreatorAllocations.length > 0) {
            _initiateCreatorVesting(asset, params.noiceCreatorAllocations);
        }

        if (noicePrebuyParticipants.length > 0) {
            _executeNoicePrebuy(
                asset,
                createData.numeraire,
                noicePrebuyParticipants,
                params.noicePrebuyCommands,
                params.noicePrebuyInputs
            );
        }
    }

    /// @notice Creates batch vesting streams for creator allocations
    /// @param asset Token to vest
    /// @param allocations Array of creator allocation configurations
    function _initiateCreatorVesting(
        address asset,
        NoiceCreatorAllocation[] calldata allocations
    ) private {
        uint256 validAllocationCount = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].amount > 0) {
                validAllocationCount++;
            }
        }

        if (validAllocationCount > 0) {
            BatchLockup.CreateWithTimestampsLL[]
                memory batch = new BatchLockup.CreateWithTimestampsLL[](
                    validAllocationCount
                );

            uint256 batchIndex = 0;
            uint256 totalBatchAmount = 0;

            for (uint256 i = 0; i < allocations.length; i++) {
                NoiceCreatorAllocation calldata allocation = allocations[i];
                if (allocation.amount > 0) {
                    batch[batchIndex] = BatchLockup.CreateWithTimestampsLL({
                        sender: address(this),
                        recipient: allocation.recipient,
                        totalAmount: uint128(allocation.amount),
                        cancelable: true,
                        transferable: true,
                        timestamps: Lockup.Timestamps({
                            start: allocation.lockStartTimestamp,
                            end: allocation.lockEndTimestamp
                        }),
                        cliffTime: 0,
                        unlockAmounts: LockupLinear.UnlockAmounts({
                            start: 0,
                            cliff: 0
                        }),
                        shape: "linear",
                        broker: Broker({
                            account: address(0),
                            fee: UD60x18.wrap(0)
                        })
                    });
                    totalBatchAmount += allocation.amount;
                    batchIndex++;
                }
            }

            IERC20(asset).approve(
                address(SABLIER_BATCH_LOCKUP),
                totalBatchAmount
            );
            SABLIER_BATCH_LOCKUP.createWithTimestampsLL(
                SABLIER_LOCKUP,
                IERC20(asset),
                batch
            );
        }
    }

    /// @notice Executes prebuy: collects NOICE, swaps to asset, distributes pro-rata with vesting
    /// @dev Pro-rata formula: participantShare = (totalAsset × participantNoice) / totalNoice
    /// @dev Designed for NOICE as numeraire (quote token), though not enforced
    /// @param asset Token being launched
    /// @param numeraire Quote token (intended to be NOICE)
    /// @param participants Array of prebuy participants
    /// @param noicePrebuyCommands UniversalRouter commands for NOICE→asset swap
    /// @param noicePrebuyInputs UniversalRouter inputs
    function _executeNoicePrebuy(
        address asset,
        address numeraire,
        NoicePrebuyParticipant[] calldata participants,
        bytes calldata noicePrebuyCommands,
        bytes[] calldata noicePrebuyInputs
    ) private {
        uint256 totalNoice = 0;

        // Collect numeraire from all participants
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i].noiceAmount > 0) {
                IERC20(numeraire).transferFrom(
                    participants[i].lockedAddress,
                    address(this),
                    participants[i].noiceAmount
                );
                totalNoice += participants[i].noiceAmount;
            }
        }

        if (totalNoice == 0) return;

        // Swap numeraire → asset
        uint256 assetBalanceBefore = IERC20(asset).balanceOf(address(this));

        IERC20(numeraire).approve(address(PERMIT2), type(uint256).max);

        PERMIT2.approve(
            numeraire,
            address(ROUTER),
            type(uint160).max,
            uint48(block.timestamp + 1 hours)
        );

        if (noicePrebuyCommands.length > 0) {
            ROUTER.execute(noicePrebuyCommands, noicePrebuyInputs);
        }

        uint256 assetBalanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 totalTokensReceived = assetBalanceAfter - assetBalanceBefore;

        if (totalTokensReceived == 0) return;

        //  Distribute tokens pro-rata with vesting
        uint256 validParticipantCount = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i].noiceAmount > 0) {
                uint256 participantShare = (totalTokensReceived *
                    participants[i].noiceAmount) / totalNoice;
                if (participantShare > 0) {
                    validParticipantCount++;
                }
            }
        }

        if (validParticipantCount > 0) {
            BatchLockup.CreateWithTimestampsLL[]
                memory batch = new BatchLockup.CreateWithTimestampsLL[](
                    validParticipantCount
                );

            uint256 batchIndex = 0;
            uint256 totalBatchAmount = 0;

            for (uint256 i = 0; i < participants.length; i++) {
                if (participants[i].noiceAmount > 0) {
                    uint256 participantShare = (totalTokensReceived *
                        participants[i].noiceAmount) / totalNoice;

                    if (participantShare > 0) {
                        batch[batchIndex] = BatchLockup.CreateWithTimestampsLL({
                            sender: address(this),
                            recipient: participants[i].vestingRecipient,
                            totalAmount: uint128(participantShare),
                            cancelable: true,
                            transferable: true,
                            timestamps: Lockup.Timestamps({
                                start: participants[i].vestingStartTimestamp,
                                end: participants[i].vestingEndTimestamp
                            }),
                            cliffTime: 0,
                            unlockAmounts: LockupLinear.UnlockAmounts({
                                start: 0,
                                cliff: 0
                            }),
                            shape: "linear",
                            broker: Broker({
                                account: address(0),
                                fee: UD60x18.wrap(0)
                            })
                        });
                        totalBatchAmount += participantShare;
                        batchIndex++;
                    }
                }
            }

            IERC20(asset).approve(
                address(SABLIER_BATCH_LOCKUP),
                totalBatchAmount
            );
            SABLIER_BATCH_LOCKUP.createWithTimestampsLL(
                SABLIER_LOCKUP,
                IERC20(asset),
                batch
            );
        }
    }

    /// @notice Creates out-of-range LP positions that convert to NOICE as price rises
    /// @dev Token0: positions above current tick | Token1: positions below current tick
    /// @param asset Token to provide as liquidity
    /// @param noiceLpUnlockAmount Total amount for LP unlock
    /// @param tranches Position configurations
    function _createNoiceLpUnlockPositions(
        address asset,
        uint256 noiceLpUnlockAmount,
        NoiceLpUnlockTranche[] calldata tranches
    ) private {
        // Validate tick ranges
        for (uint256 i = 0; i < tranches.length; i++) {
            if (tranches[i].tickLower >= tranches[i].tickUpper) {
                revert InvalidNoiceLpUnlockTranches();
            }
        }

        (, , , , IPoolInitializer poolInitializer, , , , , ) = AIRLOCK
            .getAssetData(asset);
        UniswapV4MulticurveInitializer initializer = UniswapV4MulticurveInitializer(
                address(poolInitializer)
            );
        (, , PoolKey memory poolKey, ) = initializer.getState(asset);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        (, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());

        for (uint256 i = 0; i < tranches.length; i++) {
            if (isToken0) {
                // Token0: positions must be above current tick
                if (tranches[i].tickLower <= currentTick) {
                    revert InvalidNoiceLpUnlockTranches();
                }
            } else {
                // Token1: positions must be below current tick
                if (tranches[i].tickUpper >= currentTick) {
                    revert InvalidNoiceLpUnlockTranches();
                }
            }
        }

        uint256 positionIndex = 0;
        for (uint256 i = 0; i < tranches.length; i++) {
            NoiceLpUnlockTranche calldata tranche = tranches[i];

            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(
                tranche.tickLower
            );
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(
                tranche.tickUpper
            );

            uint128 liquidity = isToken0
                ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtPriceLowerX96,
                    sqrtPriceUpperX96,
                    tranche.amount
                )
                : LiquidityAmounts.getLiquidityForAmount1(
                    sqrtPriceLowerX96,
                    sqrtPriceUpperX96,
                    tranche.amount
                );

            Position memory position = Position({
                tickLower: tranche.tickLower,
                tickUpper: tranche.tickUpper,
                liquidity: liquidity,
                salt: bytes32(uint256(keccak256(abi.encode(asset, i))))
            });

            noiceLpUnlockPositions[asset].push(position);
            noiceLpUnlockPositionRecipient[asset][positionIndex] = tranche
                .recipient;
            positionIndex++;
        }

        _mint(poolKey, noiceLpUnlockPositions[asset]);
    }

    /// @notice Returns active (non-withdrawn) LP unlock positions for an asset
    /// @param asset Token address
    /// @return Array of active Position structs
    function getNoiceLpUnlockPositions(
        address asset
    ) external view returns (Position[] memory) {
        Position[] storage allPositions = noiceLpUnlockPositions[asset];
        uint256 totalPositions = allPositions.length;

        Position[] memory activePositions = new Position[](totalPositions);
        uint256 activeCount = 0;

        for (uint256 i = 0; i < totalPositions; i++) {
            if (!noiceLpUnlockPositionWithdrawn[asset][i]) {
                activePositions[activeCount] = allPositions[i];
                activeCount++;
            }
        }

        return activePositions;
    }

    /// @notice Returns the number of active (non-withdrawn) LP unlock positions for an asset
    /// @param asset Token address
    /// @return Active position count
    function getNoiceLpUnlockPositionCount(
        address asset
    ) external view returns (uint256) {
        uint256 totalPositions = noiceLpUnlockPositions[asset].length;
        uint256 activeCount = 0;

        for (uint256 i = 0; i < totalPositions; i++) {
            if (!noiceLpUnlockPositionWithdrawn[asset][i]) {
                activeCount++;
            }
        }

        return activeCount;
    }

    /// @notice Burns LP unlock position and transfers accumulated NOICE to specified recipient
    /// @dev Callable by addresses with EXECUTOR_ROLE or owner
    /// @dev Withdraws NOICE (the pool's quote token) that accumulated from trading fees
    /// @param asset Token address
    /// @param positionIndex Index in noiceLpUnlockPositions array
    /// @param recipient Address to receive the withdrawn NOICE
    function withdrawNoiceLpUnlockPosition(
        address asset,
        uint256 positionIndex,
        address recipient
    ) external onlyRolesOrOwner(EXECUTOR_ROLE) {
        require(
            !noiceLpUnlockPositionWithdrawn[asset][positionIndex],
            "Already withdrawn"
        );
        require(
            positionIndex < noiceLpUnlockPositions[asset].length,
            "Invalid position index"
        );

        (
            address numeraire,
            ,
            ,
            ,
            IPoolInitializer poolInitializer,
            ,
            ,
            ,
            ,

        ) = AIRLOCK.getAssetData(asset);
        UniswapV4MulticurveInitializer initializer = UniswapV4MulticurveInitializer(
                address(poolInitializer)
            );
        (, , PoolKey memory poolKey, ) = initializer.getState(asset);

        Position[] memory positionsToBurn = new Position[](1);
        positionsToBurn[0] = noiceLpUnlockPositions[asset][positionIndex];

        uint256 numeraireBalanceBefore = IERC20(numeraire).balanceOf(
            address(this)
        );
        _burn(poolKey, positionsToBurn);
        uint256 numeraireBalanceAfter = IERC20(numeraire).balanceOf(
            address(this)
        );
        uint256 numeraireReceived = numeraireBalanceAfter -
            numeraireBalanceBefore;

        noiceLpUnlockPositionWithdrawn[asset][positionIndex] = true;

        if (numeraireReceived > 0) {
            IERC20(numeraire).transfer(recipient, numeraireReceived);
        }
    }

    /// @notice Cancel Sablier vesting streams and refund tokens to launchpad
    /// @dev Stream IDs obtained off-chain from Sablier creation events
    /// @dev Cancelled tokens automatically refund to launchpad (sender), use sweep() to redistribute
    /// @param streamIds Array of Sablier stream IDs to cancel
    function cancelVestingStreams(
        uint256[] calldata streamIds
    ) external onlyOwner {
        for (uint256 i = 0; i < streamIds.length; i++) {
            SABLIER_LOCKUP.cancel(streamIds[i]);
        }
    }

    /// @notice Sweep tokens or ETH from the contract to the owner
    /// @param token Address of token to sweep (address(0) for ETH)
    /// @param to Address to send the swept funds to
    function sweep(address token, address to) external onlyOwner {
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, address(this).balance);
        } else {
            SafeTransferLib.safeTransfer(
                token,
                to,
                SafeTransferLib.balanceOf(token, address(this))
            );
        }
    }

    receive() external payable {}
}
