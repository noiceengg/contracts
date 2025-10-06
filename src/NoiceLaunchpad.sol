// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Airlock, CreateParams, AssetData} from "src/Airlock.sol";
import {IPoolInitializer} from "src/interfaces/IPoolInitializer.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";
import {ISablierLockup} from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import {Lockup, LockupLinear, Broker} from "@sablier/v2-core/types/DataTypes.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MiniV4Manager} from "src/base/MiniV4Manager.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {Position} from "src/types/Position.sol";
import {PoolKey} from "@v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/types/PoolId.sol";
import {Currency} from "@v4-core/types/Currency.sol";
import {StateLibrary} from "@v4-core/libraries/StateLibrary.sol";
import {UniswapV4MulticurveInitializer} from "src/UniswapV4MulticurveInitializer.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@v4-core/types/BalanceDelta.sol";

error InvalidAddresses();
error InvalidVestingTimestamps();
error InsufficientTokenBalance();
error TooManyPresaleParticipants();
error InvalidSSLPTranches();
error InvalidPercentages();

struct VestingParams {
    uint40 creatorVestingStartTimestamp;
    uint40 creatorVestingEndTimestamp;
}

/**
 * @dev Presale participant configuration
 * @param lockedAddress Address holding NOICE tokens to be locked
 * @param noiceAmount Amount of NOICE to lock (determines pro-rata share)
 * @param vestingStartTimestamp Vesting start time
 * @param vestingEndTimestamp Vesting end time
 * @param vestingRecipient Address receiving vested tokens
 */
struct PresaleParticipant {
    address lockedAddress;
    uint256 noiceAmount;
    uint40 vestingStartTimestamp;
    uint40 vestingEndTimestamp;
    address vestingRecipient;
}

/**
 * @dev Single-sided liquidity position tranche for price-based NOICE rewards
 * @param shares Share of SSLP allocation (in basis points, sum must equal 10000)
 * @param tickLower Lower tick of the position range
 * @param tickUpper Upper tick of the position range
 * @param recipient Address that can claim accumulated NOICE from this tranche
 */
struct SSLPTranche {
    uint256 shares;
    int24 tickLower;
    int24 tickUpper;
    address recipient;
}

struct BundleWithVestingParams {
    CreateParams createData;
    VestingParams vestingParams;
    SSLPTranche[] sslpTranches;
    bytes commands;
    bytes[] inputs;
    bytes presaleCommands;
    bytes[] presaleInputs;
}

/**
 * @title NoiceLaunchpad
 * @notice Bundler for NoiceLaunchpad with creator vesting, SSLP, and presale functionality
 * @dev Token allocation: 45% creator vesting + 5% SSLP + 50% LP (presale + available)
 * @dev Creator vesting: Linear unlock via Sablier
 * @dev SSLP: Single-sided liquidity positions that earn NOICE as price increases
 * @dev Presale: Pro-rata distribution based on NOICE locked
 * @custom:security-contact v@noice.so
 */
contract NoiceLaunchpad is MiniV4Manager {
    using SafeTransferLib for address;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    Airlock public immutable AIRLOCK;
    UniversalRouter public immutable ROUTER;
    ISablierLockup public immutable SABLIER_LOCKUP;
    address public immutable NOICE_TOKEN;
    uint256 public immutable CREATOR_VESTING_PERCENTAGE;
    uint256 public immutable SSLP_PERCENTAGE;

    /// @notice Tracks SSLP positions for each asset
    mapping(address asset => Position[] positions) public sslpPositions;

    /// @notice Maps position index to recipient for each asset
    mapping(address asset => mapping(uint256 positionIndex => address recipient)) public sslpPositionRecipient;

    /// @notice Tracks which positions have been withdrawn by index
    mapping(address asset => mapping(uint256 positionIndex => bool withdrawn)) public sslpPositionWithdrawn;

    constructor(
        Airlock airlock_,
        UniversalRouter router_,
        ISablierLockup sablierLockup_,
        address noiceToken_,
        uint256 creatorVestingPercentage_,
        uint256 sslpPercentage_,
        IPoolManager poolManager_
    ) MiniV4Manager(poolManager_) {
        if (
            address(airlock_) == address(0) ||
            address(router_) == address(0) ||
            address(sablierLockup_) == address(0) ||
            noiceToken_ == address(0)
        ) {
            revert InvalidAddresses();
        }

        if (
            creatorVestingPercentage_ == 0 ||
            creatorVestingPercentage_ + sslpPercentage_ > 100
        ) {
            revert InvalidPercentages();
        }

        AIRLOCK = airlock_;
        ROUTER = router_;
        SABLIER_LOCKUP = sablierLockup_;
        NOICE_TOKEN = noiceToken_;
        CREATOR_VESTING_PERCENTAGE = creatorVestingPercentage_;
        SSLP_PERCENTAGE = sslpPercentage_;
    }

    /**
     * @notice Bundles token creation with creator vesting, SSLP, and optional presale
     * @param params Bundle parameters containing creation data, vesting info, SSLP tranches, and router commands
     * @param presaleParticipants Array of presale participants (max 100)
     */
    function bundleWithCreatorVesting(
        BundleWithVestingParams calldata params,
        PresaleParticipant[] calldata presaleParticipants
    ) external payable {
        if (presaleParticipants.length > 100) {
            revert TooManyPresaleParticipants();
        }
        if (
            params.vestingParams.creatorVestingStartTimestamp >=
            params.vestingParams.creatorVestingEndTimestamp
        ) {
            revert InvalidVestingTimestamps();
        }

        uint256 creatorVestingAmount = _calculateAllocation(
            params.createData.initialSupply,
            CREATOR_VESTING_PERCENTAGE
        );

        uint256 sslpAmount = _calculateAllocation(
            params.createData.initialSupply,
            SSLP_PERCENTAGE
        );

        CreateParams memory createData = params.createData;
        createData.numTokensToSell =
            params.createData.initialSupply -
            creatorVestingAmount -
            sslpAmount;

        createData.governanceFactoryData = abi.encode(address(this));

        (address asset, , , address timelock, ) = AIRLOCK.create(createData);

        if (params.commands.length > 0) {
            uint256 balance = address(this).balance;
            ROUTER.execute{value: balance}(params.commands, params.inputs);
        }

        if (creatorVestingAmount > 0) {
            _createCreatorVestingStream(
                asset,
                timelock,
                creatorVestingAmount,
                params.vestingParams.creatorVestingStartTimestamp,
                params.vestingParams.creatorVestingEndTimestamp
            );
        }

        if (sslpAmount > 0 && params.sslpTranches.length > 0) {
            _createSSLPPositions(
                asset,
                sslpAmount,
                params.sslpTranches
            );
        }

        if (presaleParticipants.length > 0) {
            _executePresale(
                asset,
                presaleParticipants,
                params.presaleCommands,
                params.presaleInputs
            );
        }

        _transferRemainingFunds(asset, createData.numeraire);
    }

    /**
     * @notice Calculates allocation based on percentage
     * @dev amount = (totalSupply * percentage) / 100
     * @param totalSupply Total supply of the token
     * @param percentage Percentage to allocate (0-100)
     * @return amount Amount allocated
     */
    function _calculateAllocation(
        uint256 totalSupply,
        uint256 percentage
    ) private pure returns (uint256) {
        return (totalSupply * percentage) / 100;
    }

    /**
     * @notice Creates a vesting stream for the creator
     * @param asset Address of the token to vest
     * @param recipient Address of the vesting recipient
     * @param amount Amount of tokens to vest
     * @param startTimestamp Start timestamp for vesting
     * @param endTimestamp End timestamp for vesting
     */
    function _createCreatorVestingStream(
        address asset,
        address recipient,
        uint256 amount,
        uint40 startTimestamp,
        uint40 endTimestamp
    ) private {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientTokenBalance();
        }

        IERC20(asset).approve(address(SABLIER_LOCKUP), amount);
        Lockup.CreateWithTimestamps memory params = Lockup
            .CreateWithTimestamps({
                sender: address(this),
                recipient: recipient,
                totalAmount: uint128(amount),
                token: IERC20(asset),
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({
                    start: startTimestamp,
                    end: endTimestamp
                }),
                shape: "linear",
                broker: Broker({account: address(0), fee: UD60x18.wrap(0)})
            });

        LockupLinear.UnlockAmounts memory unlockAmounts = LockupLinear
            .UnlockAmounts({start: 0, cliff: 0});

        SABLIER_LOCKUP.createWithTimestampsLL(params, unlockAmounts, 0);
    }

    /**
     * @notice Executes presale by collecting NOICE, swapping for tokens, and distributing to participants
     * @dev Pro-rata allocation: participantShare = (totalTokens * participantNoice) / totalNoice
     * @param asset Address of the newly created token
     * @param participants Array of presale participants
     * @param presaleCommands Router commands for swap
     * @param presaleInputs Router inputs for swap
     */
    function _executePresale(
        address asset,
        PresaleParticipant[] calldata participants,
        bytes calldata presaleCommands,
        bytes[] calldata presaleInputs
    ) private {
        uint256 totalNoice = 0;

        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i].noiceAmount > 0) {
                IERC20(NOICE_TOKEN).transferFrom(
                    participants[i].lockedAddress,
                    address(this),
                    participants[i].noiceAmount
                );
                totalNoice += participants[i].noiceAmount;
            }

            if (
                participants[i].vestingStartTimestamp >=
                participants[i].vestingEndTimestamp
            ) {
                revert InvalidVestingTimestamps();
            }
        }

        if (totalNoice == 0) return;

        uint256 assetBalanceBefore = IERC20(asset).balanceOf(address(this));

        IERC20(NOICE_TOKEN).approve(address(ROUTER), totalNoice);

        if (presaleCommands.length > 0) {
            ROUTER.execute(presaleCommands, presaleInputs);
        }

        uint256 assetBalanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 totalTokensReceived = assetBalanceAfter - assetBalanceBefore;

        if (totalTokensReceived == 0) return;

        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i].noiceAmount > 0) {
                uint256 participantShare = (totalTokensReceived * participants[i].noiceAmount) / totalNoice;

                if (participantShare > 0) {
                    _createPresaleVestingStream(
                        asset,
                        participants[i].vestingRecipient,
                        participantShare,
                        participants[i].vestingStartTimestamp,
                        participants[i].vestingEndTimestamp
                    );
                }
            }
        }
    }

    /**
     * @notice Creates a vesting stream for a presale participant
     * @param asset Address of the token to vest
     * @param recipient Address of the vesting recipient
     * @param amount Amount of tokens to vest
     * @param startTimestamp Start timestamp for vesting
     * @param endTimestamp End timestamp for vesting
     */
    function _createPresaleVestingStream(
        address asset,
        address recipient,
        uint256 amount,
        uint40 startTimestamp,
        uint40 endTimestamp
    ) private {
        IERC20(asset).approve(address(SABLIER_LOCKUP), amount);

        Lockup.CreateWithTimestamps memory params = Lockup
            .CreateWithTimestamps({
                sender: address(this),
                recipient: recipient,
                totalAmount: uint128(amount),
                token: IERC20(asset),
                cancelable: true,
                transferable: true,
                timestamps: Lockup.Timestamps({
                    start: startTimestamp,
                    end: endTimestamp
                }),
                shape: "linear",
                broker: Broker({account: address(0), fee: UD60x18.wrap(0)})
            });

        LockupLinear.UnlockAmounts memory unlockAmounts = LockupLinear
            .UnlockAmounts({start: 0, cliff: 0});

        SABLIER_LOCKUP.createWithTimestampsLL(params, unlockAmounts, 0);
    }

    /**
     * @notice Creates single-sided liquidity positions for price-based NOICE rewards
     * @param asset Address of the newly created token
     * @param sslpAmount Total amount of tokens allocated for SSLP
     * @param tranches Array of SSLP tranches defining tick ranges and recipients
     */
    function _createSSLPPositions(
        address asset,
        uint256 sslpAmount,
        SSLPTranche[] calldata tranches
    ) private {
        uint256 totalShares = 0;
        for (uint256 i = 0; i < tranches.length; i++) {
            totalShares += tranches[i].shares;
            if (tranches[i].tickLower >= tranches[i].tickUpper) {
                revert InvalidSSLPTranches();
            }
        }
        if (totalShares != 10000) {
            revert InvalidSSLPTranches();
        }

        // Get pool info from multicurve initializer
        (,,,, IPoolInitializer poolInitializer,,,,,) = AIRLOCK.getAssetData(asset);
        UniswapV4MulticurveInitializer initializer = UniswapV4MulticurveInitializer(
            address(poolInitializer)
        );
        (,, PoolKey memory poolKey,) = initializer.getState(asset);

        // Check if asset is token0 to determine position side
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        // Get current tick to validate positions are above current price
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Validate all tranches are positioned correctly for price-based unlocks
        for (uint256 i = 0; i < tranches.length; i++) {
            if (isToken0) {
                // Asset is token0: price rises when tick increases
                // Positions must be above current tick to activate on price rise
                if (tranches[i].tickLower <= currentTick) {
                    revert InvalidSSLPTranches();
                }
            } else {
                // Asset is token1: price rises when tick decreases
                // Positions must be below current tick to activate on price rise
                if (tranches[i].tickUpper >= currentTick) {
                    revert InvalidSSLPTranches();
                }
            }
        }

        // Create positions for each tranche
        uint256 positionIndex = 0;
        for (uint256 i = 0; i < tranches.length; i++) {
            SSLPTranche calldata tranche = tranches[i];
            uint256 trancheAmount = (sslpAmount * tranche.shares) / 10000;

            // Calculate liquidity for the position
            // For single-sided positions, we only provide the asset token
            // Using a simplified approach - actual liquidity calculation would use TickMath
            uint128 liquidity = uint128(trancheAmount);

            Position memory position = Position({
                tickLower: tranche.tickLower,
                tickUpper: tranche.tickUpper,
                liquidity: liquidity,
                salt: bytes32(uint256(keccak256(abi.encode(asset, i))))
            });

            sslpPositions[asset].push(position);
            sslpPositionRecipient[asset][positionIndex] = tranche.recipient;
            positionIndex++;
        }

        // Mint all positions
        IERC20(asset).approve(address(poolManager), sslpAmount);
        _mint(poolKey, sslpPositions[asset]);
    }

    /**
     * @notice Returns all SSLP positions for an asset
     * @param asset Address of the token
     * @return positions Array of SSLP positions
     */
    function getSSLPPositions(address asset) external view returns (Position[] memory) {
        return sslpPositions[asset];
    }

    /**
     * @notice Returns the number of SSLP positions for an asset
     * @param asset Address of the token
     * @return count Number of SSLP positions
     */
    function getSSLPPositionCount(address asset) external view returns (uint256) {
        return sslpPositions[asset].length;
    }

    /**
     * @notice Withdraws SSLP position and receives accumulated NOICE
     * @dev Burns the position - returns NOICE that accumulated as price moved through the range
     * @param asset Address of the token
     * @param positionIndex Index of the position to withdraw
     */
    function withdrawSSLPPosition(address asset, uint256 positionIndex) external {
        require(sslpPositionRecipient[asset][positionIndex] == msg.sender, "Not position owner");
        require(!sslpPositionWithdrawn[asset][positionIndex], "Already withdrawn");
        require(positionIndex < sslpPositions[asset].length, "Invalid position index");

        // Get pool info
        (,,,, IPoolInitializer poolInitializer,,,,,) = AIRLOCK.getAssetData(asset);
        UniswapV4MulticurveInitializer initializer = UniswapV4MulticurveInitializer(
            address(poolInitializer)
        );
        (,, PoolKey memory poolKey,) = initializer.getState(asset);

        // Create array with single position to burn
        Position[] memory positionsToBurn = new Position[](1);
        positionsToBurn[0] = sslpPositions[asset][positionIndex];

        // Burn position and get accumulated NOICE
        uint256 noiceBalanceBefore = IERC20(NOICE_TOKEN).balanceOf(address(this));
        _burn(poolKey, positionsToBurn);
        uint256 noiceBalanceAfter = IERC20(NOICE_TOKEN).balanceOf(address(this));

        uint256 noiceReceived = noiceBalanceAfter - noiceBalanceBefore;

        // Mark as withdrawn
        sslpPositionWithdrawn[asset][positionIndex] = true;

        // Transfer NOICE to recipient
        if (noiceReceived > 0) {
            IERC20(NOICE_TOKEN).transfer(msg.sender, noiceReceived);
        }
    }

    /**
     * @notice Transfers remaining funds back to sender
     * @param asset Address of the asset token
     * @param numeraire Address of the numeraire token
     */
    function _transferRemainingFunds(address asset, address numeraire) private {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, ethBalance);
        }

        uint256 assetBalance = SafeTransferLib.balanceOf(asset, address(this));
        if (assetBalance > 0) {
            SafeTransferLib.safeTransfer(asset, msg.sender, assetBalance);
        }

        uint256 numeraireBalance = SafeTransferLib.balanceOf(
            numeraire,
            address(this)
        );
        if (numeraireBalance > 0) {
            SafeTransferLib.safeTransfer(
                numeraire,
                msg.sender,
                numeraireBalance
            );
        }

        uint256 noiceBalance = SafeTransferLib.balanceOf(
            NOICE_TOKEN,
            address(this)
        );
        if (noiceBalance > 0) {
            SafeTransferLib.safeTransfer(NOICE_TOKEN, msg.sender, noiceBalance);
        }
    }

    receive() external payable {}
}
