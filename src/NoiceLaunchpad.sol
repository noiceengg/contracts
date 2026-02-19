// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";
import { LibCall } from "@solady/utils/LibCall.sol";
import { Airlock, CreateParams } from "src/Airlock.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { ISablierLockup } from "@sablier/v2-core/interfaces/ISablierLockup.sol";
import { ISablierBatchLockup } from "@sablier/v2-core/interfaces/ISablierBatchLockup.sol";
import { Lockup, LockupLinear, Broker, BatchLockup } from "@sablier/v2-core/types/DataTypes.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { MiniV4Manager } from "src/base/MiniV4Manager.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Position } from "src/types/Position.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { UniswapV4MulticurveInitializer } from "src/UniswapV4MulticurveInitializer.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

error InvalidAddresses();
error InsufficientTokenBalance();
error InvalidNumeraireLpUnlockTranches();
error TokenFactoryVestingNotSupported();
error UnauthorizedNumeraireLpUnlockWithdrawal();
error InvalidPrebuyTranche();
error InvalidPrebuyTrancheWindow();
error InvalidPrebuyCommit();
error InvalidPrebuyReveal();
error InvalidPrebuySettlement();
error PrebuyAlreadySettled();
error PrebuyNotSettled();
error PrebuyAlreadyClaimed();
error InvalidVestingConfig();

struct NumeraireCreatorAllocation {
    address recipient;
    uint256 amount;
    uint40 lockStartTimestamp;
    uint40 lockEndTimestamp;
}

struct NumeraireLpUnlockTranche {
    uint256 amount;
    int24 tickLower;
    int24 tickUpper;
    address recipient;
}

struct PrebuyTranche {
    uint40 commitStart;
    uint40 commitEnd;
    uint40 revealStart;
    uint40 revealEnd;
    uint256 assetAllocation;
}

struct NumerairePrebuyCommit {
    bytes32 commitment;
    address fundingWallet;
    uint256 trancheId;
}

struct NumerairePrebuyReveal {
    address fundingWallet;
    uint256 trancheId;
    uint256 numeraireAmount;
    address recipient;
    bool useVesting;
    uint40 vestingStartTimestamp;
    uint40 vestingEndTimestamp;
    bytes32 salt;
}

struct BundleParams {
    CreateParams createData;
    NumeraireCreatorAllocation[] creatorAllocations;
    NumeraireLpUnlockTranche[] numeraireLpUnlockTranches;
    PrebuyTranche[] prebuyTranches;
    bytes noicePrebuyCommands;
    bytes[] noicePrebuyInputs;
}

struct TrancheState {
    uint256 revealedNumeraire;
    uint256 distributableAsset;
    uint256 carryIn;
    uint256 carryOut;
    bool settled;
}

// Legacy compatibility structs/errors for old scripts/tests.
error InvalidVestingTimestamps();
error TooManyPresaleParticipants();

struct VestingParams {
    uint40 creatorVestingStartTimestamp;
    uint40 creatorVestingEndTimestamp;
}

struct PresaleParticipant {
    address lockedAddress;
    uint256 noiceAmount;
    uint40 vestingStartTimestamp;
    uint40 vestingEndTimestamp;
    address vestingRecipient;
}

struct SSLPTranche {
    uint256 amount;
    int24 tickLower;
    int24 tickUpper;
    address recipient;
}

struct NoiceCreatorAllocation {
    address recipient;
    uint256 amount;
    uint40 lockStartTimestamp;
    uint40 lockEndTimestamp;
}

struct NoicePrebuyParticipant {
    address lockedAddress;
    uint256 noiceAmount;
    uint40 vestingStartTimestamp;
    uint40 vestingEndTimestamp;
    address vestingRecipient;
}

struct NoiceLpUnlockTranche {
    uint256 amount;
    int24 tickLower;
    int24 tickUpper;
    address recipient;
}

struct BundleWithVestingParams {
    CreateParams createData;
    NoiceCreatorAllocation[] noiceCreatorAllocations;
    NoiceLpUnlockTranche[] noiceLpUnlockTranches;
    bytes noicePrebuyCommands;
    bytes[] noicePrebuyInputs;
}

contract NumeraireLaunchpad is MiniV4Manager, OwnableRoles {
    using SafeTransferLib for address;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    Airlock public immutable AIRLOCK;
    UniversalRouter public immutable ROUTER;
    ISablierLockup public immutable SABLIER_LOCKUP;
    ISablierBatchLockup public immutable SABLIER_BATCH_LOCKUP;
    IPermit2 private constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    uint256 public constant EXECUTOR_ROLE = _ROLE_0;

    mapping(address asset => Position[] positions) public numeraireLpUnlockPositions;
    mapping(address asset => mapping(uint256 positionIndex => address recipient)) public numeraireLpUnlockPositionRecipient;
    mapping(address asset => mapping(uint256 positionIndex => bool withdrawn)) public numeraireLpUnlockPositionWithdrawn;
    mapping(address asset => address creator) public assetCreator;

    mapping(address asset => PrebuyTranche[] tranches) public prebuyTranches;
    mapping(address asset => mapping(uint256 trancheId => TrancheState state)) public trancheState;
    mapping(address asset => mapping(uint256 trancheId => mapping(bytes32 commitment => bool committed))) public prebuyCommitmentExists;
    mapping(address asset => mapping(uint256 trancheId => mapping(bytes32 commitment => bool consumed))) public prebuyCommitmentConsumed;
    mapping(address asset => mapping(uint256 trancheId => mapping(bytes32 commitment => uint256 amount))) public prebuyRevealedNumeraire;
    mapping(address asset => mapping(uint256 trancheId => mapping(bytes32 commitment => bool claimed))) public prebuyClaimed;

    event PrebuyCommitted(address indexed asset, uint256 indexed trancheId, address indexed fundingWallet, bytes32 commitment);
    event PrebuyRevealed(address indexed asset, uint256 indexed trancheId, bytes32 indexed commitment, uint256 numeraireAmount);
    event PrebuyTrancheSettled(
        address indexed asset,
        uint256 indexed trancheId,
        uint256 revealedNumeraire,
        uint256 distributableAsset,
        uint256 carryOut
    );
    event PrebuyAllocated(address indexed asset, uint256 indexed trancheId, bytes32 indexed commitment, address recipient, uint256 amount, bool vested);

    constructor(
        Airlock airlock_,
        UniversalRouter router_,
        ISablierLockup sablierLockup_,
        ISablierBatchLockup sablierBatchLockup_,
        IPoolManager poolManager_,
        address owner_
    ) MiniV4Manager(poolManager_) {
        if (
            address(airlock_) == address(0) || address(router_) == address(0) || address(sablierLockup_) == address(0)
                || address(sablierBatchLockup_) == address(0) || address(poolManager_) == address(0) || owner_ == address(0)
        ) revert InvalidAddresses();

        AIRLOCK = airlock_;
        ROUTER = router_;
        SABLIER_LOCKUP = sablierLockup_;
        SABLIER_BATCH_LOCKUP = sablierBatchLockup_;
        _initializeOwner(owner_);
    }

    function bundleWithCreatorAllocations(BundleParams memory params) public payable {
        address creator = msg.sender;

        (,,,, address[] memory vestingRecipients, uint256[] memory vestingAmounts,) = abi.decode(
            params.createData.tokenFactoryData, (string, string, uint256, uint256, address[], uint256[], string)
        );
        if (vestingRecipients.length > 0 || vestingAmounts.length > 0) revert TokenFactoryVestingNotSupported();

        uint256 totalCreatorAllocationAmount;
        for (uint256 i = 0; i < params.creatorAllocations.length; i++) {
            totalCreatorAllocationAmount += params.creatorAllocations[i].amount;
        }

        uint256 totalLpUnlockAmount;
        for (uint256 i = 0; i < params.numeraireLpUnlockTranches.length; i++) {
            totalLpUnlockAmount += params.numeraireLpUnlockTranches[i].amount;
        }

        uint256 totalPrebuyAllocation;
        for (uint256 i = 0; i < params.prebuyTranches.length; i++) {
            _validatePrebuyTranche(params.prebuyTranches[i], i == 0 ? uint40(0) : params.prebuyTranches[i - 1].revealEnd);
            totalPrebuyAllocation += params.prebuyTranches[i].assetAllocation;
        }

        CreateParams memory createData = params.createData;
        createData.numTokensToSell = params.createData.initialSupply - totalCreatorAllocationAmount - totalLpUnlockAmount - totalPrebuyAllocation;
        createData.governanceFactoryData = abi.encode(creator);
        createData.integrator = creator;

        (address asset,,,,) = AIRLOCK.create(createData);
        assetCreator[asset] = creator;

        for (uint256 i = 0; i < params.prebuyTranches.length; i++) {
            prebuyTranches[asset].push(params.prebuyTranches[i]);
        }

        if (totalLpUnlockAmount > 0) {
            _createNumeraireLpUnlockPositions(asset, params.numeraireLpUnlockTranches);
        }

        if (params.creatorAllocations.length > 0) {
            _allocateCreatorTokens(asset, params.creatorAllocations);
        }
    }

    function commitPrebuy(address asset, NumerairePrebuyCommit calldata commitData) external {
        if (commitData.fundingWallet == address(0)) revert InvalidPrebuyCommit();
        if (commitData.trancheId >= prebuyTranches[asset].length) revert InvalidPrebuyTranche();
        PrebuyTranche memory tranche = prebuyTranches[asset][commitData.trancheId];
        if (block.timestamp < tranche.commitStart || block.timestamp > tranche.commitEnd) revert InvalidPrebuyTrancheWindow();
        if (prebuyCommitmentExists[asset][commitData.trancheId][commitData.commitment]) revert InvalidPrebuyCommit();

        prebuyCommitmentExists[asset][commitData.trancheId][commitData.commitment] = true;
        emit PrebuyCommitted(asset, commitData.trancheId, commitData.fundingWallet, commitData.commitment);
    }

    function revealPrebuy(address asset, NumerairePrebuyReveal calldata revealData) external {
        if (revealData.fundingWallet == address(0) || revealData.recipient == address(0) || revealData.numeraireAmount == 0) {
            revert InvalidPrebuyReveal();
        }
        if (revealData.trancheId >= prebuyTranches[asset].length) revert InvalidPrebuyTranche();

        PrebuyTranche memory tranche = prebuyTranches[asset][revealData.trancheId];
        if (block.timestamp < tranche.revealStart || block.timestamp > tranche.revealEnd) revert InvalidPrebuyTrancheWindow();

        bytes32 commitment = _computeCommitment(asset, revealData);
        if (!prebuyCommitmentExists[asset][revealData.trancheId][commitment]) revert InvalidPrebuyReveal();
        if (prebuyCommitmentConsumed[asset][revealData.trancheId][commitment]) revert InvalidPrebuyReveal();

        if (revealData.useVesting) {
            if (revealData.vestingStartTimestamp >= revealData.vestingEndTimestamp) revert InvalidVestingConfig();
        }

        prebuyCommitmentConsumed[asset][revealData.trancheId][commitment] = true;
        prebuyRevealedNumeraire[asset][revealData.trancheId][commitment] = revealData.numeraireAmount;
        trancheState[asset][revealData.trancheId].revealedNumeraire += revealData.numeraireAmount;

        IERC20(_numeraire(asset)).transferFrom(revealData.fundingWallet, address(this), revealData.numeraireAmount);

        emit PrebuyRevealed(asset, revealData.trancheId, commitment, revealData.numeraireAmount);
    }

    function settlePrebuyTranche(address asset, uint256 trancheId, bytes calldata swapCommands, bytes[] calldata swapInputs) external {
        if (trancheId >= prebuyTranches[asset].length) revert InvalidPrebuyTranche();
        PrebuyTranche memory tranche = prebuyTranches[asset][trancheId];
        TrancheState storage state = trancheState[asset][trancheId];
        if (state.settled) revert PrebuyAlreadySettled();
        if (block.timestamp <= tranche.revealEnd) revert InvalidPrebuyTrancheWindow();

        uint256 totalNumeraire = state.revealedNumeraire;
        uint256 assetReceived;

        if (totalNumeraire > 0) {
            address numeraire = _numeraire(asset);
            uint256 assetBalanceBefore = IERC20(asset).balanceOf(address(this));

            IERC20(numeraire).approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(numeraire, address(ROUTER), type(uint160).max, uint48(block.timestamp + 1 hours));
            ROUTER.execute(swapCommands, swapInputs);

            uint256 assetBalanceAfter = IERC20(asset).balanceOf(address(this));
            assetReceived = assetBalanceAfter - assetBalanceBefore;
        }

        uint256 cap = tranche.assetAllocation + state.carryIn;
        uint256 distributable = assetReceived < cap ? assetReceived : cap;
        state.distributableAsset = distributable;
        state.carryOut = cap - distributable;
        state.settled = true;

        if (trancheId + 1 < prebuyTranches[asset].length) {
            trancheState[asset][trancheId + 1].carryIn += state.carryOut;
        }

        emit PrebuyTrancheSettled(asset, trancheId, totalNumeraire, distributable, state.carryOut);
    }

    function claimPrebuyAllocation(address asset, NumerairePrebuyReveal calldata revealData) external {
        if (revealData.trancheId >= prebuyTranches[asset].length) revert InvalidPrebuyTranche();

        bytes32 commitment = _computeCommitment(asset, revealData);
        TrancheState storage state = trancheState[asset][revealData.trancheId];
        if (!state.settled) revert PrebuyNotSettled();
        if (prebuyClaimed[asset][revealData.trancheId][commitment]) revert PrebuyAlreadyClaimed();

        uint256 committedAmount = prebuyRevealedNumeraire[asset][revealData.trancheId][commitment];
        if (committedAmount == 0) revert InvalidPrebuyReveal();

        prebuyClaimed[asset][revealData.trancheId][commitment] = true;

        uint256 allocation = state.revealedNumeraire == 0 ? 0 : (state.distributableAsset * committedAmount) / state.revealedNumeraire;
        if (allocation == 0) return;

        if (revealData.useVesting) {
            if (revealData.vestingStartTimestamp >= revealData.vestingEndTimestamp) revert InvalidVestingConfig();
            _createSingleVestingStream(asset, revealData.recipient, allocation, revealData.vestingStartTimestamp, revealData.vestingEndTimestamp);
        } else {
            IERC20(asset).transfer(revealData.recipient, allocation);
        }

        emit PrebuyAllocated(asset, revealData.trancheId, commitment, revealData.recipient, allocation, revealData.useVesting);
    }

    function getNumeraireLpUnlockPositions(address asset) public view returns (Position[] memory) {
        Position[] storage allPositions = numeraireLpUnlockPositions[asset];
        uint256 totalPositions = allPositions.length;

        Position[] memory activePositions = new Position[](totalPositions);
        uint256 activeCount;

        for (uint256 i = 0; i < totalPositions; i++) {
            if (!numeraireLpUnlockPositionWithdrawn[asset][i]) {
                activePositions[activeCount] = allPositions[i];
                activeCount++;
            }
        }

        return activePositions;
    }

    function getNumeraireLpUnlockPositionCount(address asset) public view returns (uint256) {
        uint256 totalPositions = numeraireLpUnlockPositions[asset].length;
        uint256 activeCount;

        for (uint256 i = 0; i < totalPositions; i++) {
            if (!numeraireLpUnlockPositionWithdrawn[asset][i]) {
                activeCount++;
            }
        }

        return activeCount;
    }

    function withdrawNumeraireLpUnlockPosition(address asset, uint256 positionIndex, address recipient) public {
        require(!numeraireLpUnlockPositionWithdrawn[asset][positionIndex], "Already withdrawn");
        require(positionIndex < numeraireLpUnlockPositions[asset].length, "Invalid position index");
        if (
            msg.sender != assetCreator[asset]
                && msg.sender != numeraireLpUnlockPositionRecipient[asset][positionIndex]
        ) revert UnauthorizedNumeraireLpUnlockWithdrawal();

        (address numeraire,,,, IPoolInitializer poolInitializer,,,,,) = AIRLOCK.getAssetData(asset);
        UniswapV4MulticurveInitializer initializer = UniswapV4MulticurveInitializer(address(poolInitializer));
        (,, PoolKey memory poolKey,) = initializer.getState(asset);

        Position[] memory positionsToBurn = new Position[](1);
        positionsToBurn[0] = numeraireLpUnlockPositions[asset][positionIndex];

        uint256 numeraireBalanceBefore = IERC20(numeraire).balanceOf(address(this));
        _burn(poolKey, positionsToBurn);
        uint256 numeraireBalanceAfter = IERC20(numeraire).balanceOf(address(this));
        uint256 numeraireReceived = numeraireBalanceAfter - numeraireBalanceBefore;

        numeraireLpUnlockPositionWithdrawn[asset][positionIndex] = true;

        if (numeraireReceived > 0) {
            IERC20(numeraire).transfer(recipient, numeraireReceived);
        }
    }

    function cancelVestingStreams(uint256[] calldata streamIds) external onlyOwner {
        for (uint256 i = 0; i < streamIds.length; i++) {
            SABLIER_LOCKUP.cancel(streamIds[i]);
        }
    }

    function sweep(address token, address to) external onlyOwner {
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, address(this).balance);
        } else {
            SafeTransferLib.safeTransfer(token, to, SafeTransferLib.balanceOf(token, address(this)));
        }
    }

    function execute(address[] calldata targets, uint256[] calldata values, bytes[] calldata data) external payable onlyOwner returns (bytes[] memory results) {
        require(targets.length == values.length && targets.length == data.length, "Length mismatch");
        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            results[i] = LibCall.callContract(targets[i], values[i], data[i]);
        }
    }

    function _allocateCreatorTokens(address asset, NumeraireCreatorAllocation[] memory allocations) private {
        for (uint256 i = 0; i < allocations.length; i++) {
            NumeraireCreatorAllocation memory allocation = allocations[i];
            if (allocation.amount == 0) continue;

            if (allocation.lockStartTimestamp != 0 || allocation.lockEndTimestamp != 0) {
                if (allocation.lockStartTimestamp >= allocation.lockEndTimestamp) revert InvalidVestingConfig();
                _createSingleVestingStream(asset, allocation.recipient, allocation.amount, allocation.lockStartTimestamp, allocation.lockEndTimestamp);
            } else {
                IERC20(asset).transfer(allocation.recipient, allocation.amount);
            }
        }
    }

    function _createSingleVestingStream(
        address asset,
        address recipient,
        uint256 amount,
        uint40 start,
        uint40 end
    ) private {
        if (SafeTransferLib.balanceOf(asset, address(this)) < amount) revert InsufficientTokenBalance();

        BatchLockup.CreateWithTimestampsLL[] memory batch = new BatchLockup.CreateWithTimestampsLL[](1);
        batch[0] = BatchLockup.CreateWithTimestampsLL({
            sender: address(this),
            recipient: recipient,
            totalAmount: uint128(amount),
            cancelable: true,
            transferable: true,
            timestamps: Lockup.Timestamps({ start: start, end: end }),
            cliffTime: 0,
            unlockAmounts: LockupLinear.UnlockAmounts({ start: 0, cliff: 0 }),
            shape: "linear",
            broker: Broker({ account: address(0), fee: UD60x18.wrap(0) })
        });

        IERC20(asset).approve(address(SABLIER_BATCH_LOCKUP), amount);
        SABLIER_BATCH_LOCKUP.createWithTimestampsLL(SABLIER_LOCKUP, IERC20(asset), batch);
    }

    function _createNumeraireLpUnlockPositions(address asset, NumeraireLpUnlockTranche[] memory tranches) private {
        for (uint256 i = 0; i < tranches.length; i++) {
            if (tranches[i].tickLower >= tranches[i].tickUpper) revert InvalidNumeraireLpUnlockTranches();
        }

        (,,,, IPoolInitializer poolInitializer,,,,,) = AIRLOCK.getAssetData(asset);
        UniswapV4MulticurveInitializer initializer = UniswapV4MulticurveInitializer(address(poolInitializer));
        (,, PoolKey memory poolKey,) = initializer.getState(asset);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        for (uint256 i = 0; i < tranches.length; i++) {
            if (isToken0) {
                if (tranches[i].tickLower <= currentTick) revert InvalidNumeraireLpUnlockTranches();
            } else {
                if (tranches[i].tickUpper >= currentTick) revert InvalidNumeraireLpUnlockTranches();
            }
        }

        uint256 positionIndex;
        for (uint256 i = 0; i < tranches.length; i++) {
            NumeraireLpUnlockTranche memory tranche = tranches[i];

            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tranche.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tranche.tickUpper);

            uint128 liquidity = isToken0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLowerX96, sqrtPriceUpperX96, tranche.amount)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, tranche.amount);

            Position memory position = Position({
                tickLower: tranche.tickLower,
                tickUpper: tranche.tickUpper,
                liquidity: liquidity,
                salt: bytes32(uint256(keccak256(abi.encode(asset, i))))
            });

            numeraireLpUnlockPositions[asset].push(position);
            numeraireLpUnlockPositionRecipient[asset][positionIndex] = tranche.recipient;
            positionIndex++;
        }

        _mint(poolKey, numeraireLpUnlockPositions[asset]);
    }

    function _validatePrebuyTranche(PrebuyTranche memory tranche, uint40 previousRevealEnd) private pure {
        if (
            tranche.commitStart >= tranche.commitEnd || tranche.commitEnd > tranche.revealStart
                || tranche.revealStart >= tranche.revealEnd
        ) revert InvalidPrebuyTranche();
        if (tranche.commitStart < previousRevealEnd) revert InvalidPrebuyTranche();
    }

    function _computeCommitment(address asset, NumerairePrebuyReveal calldata revealData) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                asset,
                revealData.trancheId,
                revealData.fundingWallet,
                revealData.numeraireAmount,
                revealData.recipient,
                revealData.useVesting,
                revealData.vestingStartTimestamp,
                revealData.vestingEndTimestamp,
                revealData.salt
            )
        );
    }

    function _numeraire(address asset) private view returns (address numeraire) {
        (numeraire,,,,,,,,,) = AIRLOCK.getAssetData(asset);
    }

    receive() external payable { }
}

/// @dev Backward compatible wrapper for old interfaces while new implementation lives in NumeraireLaunchpad.
contract NoiceLaunchpad is NumeraireLaunchpad {
    constructor(
        Airlock airlock_,
        UniversalRouter router_,
        ISablierLockup sablierLockup_,
        ISablierBatchLockup sablierBatchLockup_,
        IPoolManager poolManager_,
        address owner_
    ) NumeraireLaunchpad(airlock_, router_, sablierLockup_, sablierBatchLockup_, poolManager_, owner_) { }

    function bundleWithCreatorVesting(
        BundleWithVestingParams calldata params,
        NoicePrebuyParticipant[] calldata
    ) external payable {
        uint256 len = params.noiceCreatorAllocations.length;
        NumeraireCreatorAllocation[] memory creatorAllocs = new NumeraireCreatorAllocation[](len);
        for (uint256 i = 0; i < len; i++) {
            creatorAllocs[i] = NumeraireCreatorAllocation({
                recipient: params.noiceCreatorAllocations[i].recipient,
                amount: params.noiceCreatorAllocations[i].amount,
                lockStartTimestamp: params.noiceCreatorAllocations[i].lockStartTimestamp,
                lockEndTimestamp: params.noiceCreatorAllocations[i].lockEndTimestamp
            });
        }

        uint256 trLen = params.noiceLpUnlockTranches.length;
        NumeraireLpUnlockTranche[] memory lpTranches = new NumeraireLpUnlockTranche[](trLen);
        for (uint256 i = 0; i < trLen; i++) {
            lpTranches[i] = NumeraireLpUnlockTranche({
                amount: params.noiceLpUnlockTranches[i].amount,
                tickLower: params.noiceLpUnlockTranches[i].tickLower,
                tickUpper: params.noiceLpUnlockTranches[i].tickUpper,
                recipient: params.noiceLpUnlockTranches[i].recipient
            });
        }

        BundleParams memory newParams = BundleParams({
            createData: params.createData,
            creatorAllocations: creatorAllocs,
            numeraireLpUnlockTranches: lpTranches,
            prebuyTranches: new PrebuyTranche[](0),
            noicePrebuyCommands: params.noicePrebuyCommands,
            noicePrebuyInputs: params.noicePrebuyInputs
        });

        bundleWithCreatorAllocations(newParams);
    }

    function withdrawNoiceLpUnlockPosition(address asset, uint256 positionIndex, address recipient) external {
        withdrawNumeraireLpUnlockPosition(asset, positionIndex, recipient);
    }

    function getNoiceLpUnlockPositions(address asset) external view returns (Position[] memory) {
        return getNumeraireLpUnlockPositions(asset);
    }

    function getNoiceLpUnlockPositionCount(address asset) external view returns (uint256) {
        return getNumeraireLpUnlockPositionCount(asset);
    }

    function noiceLpUnlockPositionRecipient(address asset, uint256 positionIndex) external view returns (address) {
        return numeraireLpUnlockPositionRecipient[asset][positionIndex];
    }

    function noiceLpUnlockPositionWithdrawn(address asset, uint256 positionIndex) external view returns (bool) {
        return numeraireLpUnlockPositionWithdrawn[asset][positionIndex];
    }
}
