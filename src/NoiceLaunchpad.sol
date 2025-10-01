// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Airlock, CreateParams} from "src/Airlock.sol";
import {UniversalRouter} from "@universal-router/UniversalRouter.sol";
import {ISablierLockup} from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import {Lockup, LockupLinear, Broker} from "@sablier/v2-core/types/DataTypes.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

error InvalidAddresses();
error InvalidVestingTimestamps();
error InsufficientTokenBalance();
error TooManyPresaleParticipants();

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

struct BundleWithVestingParams {
    CreateParams createData;
    VestingParams vestingParams;
    bytes commands;
    bytes[] inputs;
    bytes presaleCommands;
    bytes[] presaleInputs;
}

/**
 * @title NoiceLaunchpad
 * @notice Bundler for NoiceLaunchpad with creator vesting and presale functionality
 * @dev Token allocation: 45% creator vesting + 55% available (presale + LP)
 * @dev Creator vesting: Linear unlock via Sablier
 * @dev Presale: Pro-rata distribution based on NOICE locked
 * @custom:security-contact v@noice.so
 */
contract NoiceLaunchpad {
    using SafeTransferLib for address;

    Airlock public immutable airlock;
    UniversalRouter public immutable router;
    ISablierLockup public immutable sablierLockup;
    address public immutable NOICE_TOKEN;
    uint256 public immutable CREATOR_VESTING_PERCENTAGE;

    constructor(
        Airlock airlock_,
        UniversalRouter router_,
        ISablierLockup sablierLockup_,
        address noiceToken_,
        uint256 creatorVestingPercentage_
    ) {
        if (
            address(airlock_) == address(0) ||
            address(router_) == address(0) ||
            address(sablierLockup_) == address(0) ||
            noiceToken_ == address(0) ||
            creatorVestingPercentage_ == 0 ||
            creatorVestingPercentage_ > 100
        ) {
            revert InvalidAddresses();
        }

        airlock = airlock_;
        router = router_;
        sablierLockup = sablierLockup_;
        NOICE_TOKEN = noiceToken_;
        CREATOR_VESTING_PERCENTAGE = creatorVestingPercentage_;
    }

    /**
     * @notice Bundles token creation with 45% creator vesting and optional presale
     * @param params Bundle parameters containing creation data, vesting info, and router commands
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

        uint256 creatorVestingAmount = _calculateVestingAllocation(
            params.createData.initialSupply
        );

        CreateParams memory createData = params.createData;
        createData.numTokensToSell =
            params.createData.initialSupply -
            creatorVestingAmount;

        createData.governanceFactoryData = abi.encode(address(this));

        (address asset, , , address timelock, ) = airlock.create(createData);

        if (params.commands.length > 0) {
            uint256 balance = address(this).balance;
            router.execute{value: balance}(params.commands, params.inputs);
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
     * @notice Calculates the creator vesting allocation
     * @dev vestingAmount = (totalSupply * percentage) / 100
     * @param totalSupply Total supply of the token
     * @return vestingAmount Amount allocated for creator vesting
     */
    function _calculateVestingAllocation(
        uint256 totalSupply
    ) private view returns (uint256) {
        return (totalSupply * CREATOR_VESTING_PERCENTAGE) / 100;
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

        IERC20(asset).approve(address(sablierLockup), amount);
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

        sablierLockup.createWithTimestampsLL(params, unlockAmounts, 0);
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

        IERC20(NOICE_TOKEN).approve(address(router), totalNoice);

        if (presaleCommands.length > 0) {
            router.execute(presaleCommands, presaleInputs);
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
        IERC20(asset).approve(address(sablierLockup), amount);

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

        sablierLockup.createWithTimestampsLL(params, unlockAmounts, 0);
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
