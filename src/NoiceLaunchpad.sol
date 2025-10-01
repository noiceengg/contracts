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

struct VestingParams {
    uint40 creatorVestingStartTimestamp;
    uint40 creatorVestingEndTimestamp;
}

struct BundleWithVestingParams {
    CreateParams createData;
    VestingParams vestingParams;
    bytes commands;
    bytes[] inputs;
}

/**
 * @title NoiceLaunchpad
 * @notice Bundler for NoiceLaunchpad with creator vesting functionality
 * @dev Allocates 45% of tokens to creator with linear vesting via Sablier
 * @custom:security-contact v@noice.so
 */
contract NoiceLaunchpad {
    using SafeTransferLib for address;

    /// @notice Address of the Airlock contract
    Airlock public immutable airlock;

    /// @notice Address of the Universal Router contract
    UniversalRouter public immutable router;

    /// @notice Address of the Sablier Lockup contract (Base mainnet)
    ISablierLockup public immutable sablierLockup;

    /// @notice NOICE token address on Base mainnet
    address public constant NOICE_TOKEN =
        0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;

    /// @notice Sablier Lockup Linear address on Base mainnet
    address public constant SABLIER_LOCKUP_LINEAR =
        0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B;

    /// @notice Creator vesting allocation percentage (45%)
    uint256 public constant CREATOR_VESTING_PERCENTAGE = 45;

    /**
     * @param airlock_ Immutable address of the Airlock contract
     * @param router_ Immutable address of the Universal Router contract
     * @param sablierLockup_ Immutable address of the Sablier Lockup contract
     */
    constructor(
        Airlock airlock_,
        UniversalRouter router_,
        ISablierLockup sablierLockup_
    ) {
        if (
            address(airlock_) == address(0) ||
            address(router_) == address(0) ||
            address(sablierLockup_) == address(0)
        ) {
            revert InvalidAddresses();
        }

        airlock = airlock_;
        router = router_;
        sablierLockup = sablierLockup_;
    }

    /**
     * @notice Bundles token creation with 45% creator vesting
     * @param params Bundle parameters containing creation data, vesting info, and router commands
     */
    function bundleWithCreatorVesting(
        BundleWithVestingParams calldata params
    ) external payable {
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

        _transferRemainingFunds(asset, createData.numeraire);
    }

    /**
     * @notice Calculates the creator vesting allocation (45% of total supply)
     * @param totalSupply Total supply of the token
     * @return vestingAmount Amount allocated for creator vesting
     */
    function _calculateVestingAllocation(
        uint256 totalSupply
    ) private pure returns (uint256) {
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
