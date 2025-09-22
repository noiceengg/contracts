 
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";

import { AirlockWithVesting, CreateWithVestingParams } from "src/AirlockWithVesting.sol";
import { IVestingFactory } from "src/vesting/IVestingFactory.sol";

error PresaleOverAllocation();

struct PresaleParticipant {
    address account;
    uint256 quoteAmount;
}
contract PresaleBundler {
    using SafeTransferLib for ERC20;

    event PresaleVestingCreated(address indexed asset, address indexed beneficiary, address vesting, uint256 amount);
    event QuoteForwarded(address indexed token, address indexed recipient, uint256 amount);

    AirlockWithVesting public immutable airlock;
    address public expectedNumeraire;
    address public vestingFactory;

    constructor(AirlockWithVesting airlock_) {
        airlock = airlock_;
    }

    function setExpectedNumeraire(address numeraire) external {
        require(msg.sender == airlock.owner(), "not owner");
        expectedNumeraire = numeraire;
    }

    function setVestingFactory(address factory) external {
        require(msg.sender == airlock.owner(), "not owner");
        vestingFactory = factory;
    }

    function launchAndDistribute(
        CreateWithVestingParams calldata p,
        bytes calldata poolInitializerData,
        PresaleParticipant[] calldata participants,
        uint256 priceWad,
        uint64 vestStart,
        uint64 vestDuration,
        address quoteRecipient
    ) external returns (address asset) {
        require(p.presaleDistributor == address(this), "presaleDistributor != bundler");
        if (expectedNumeraire != address(0)) {
            require(p.numeraire == expectedNumeraire, "unexpected numeraire");
        }
        (asset,,,,) = airlock.createWithVesting(
            CreateWithVestingParams({
                initialSupply: p.initialSupply,
                numTokensToSell: p.numTokensToSell,
                numeraire: p.numeraire,
                tokenFactory: p.tokenFactory,
                tokenFactoryData: p.tokenFactoryData,
                governanceFactory: p.governanceFactory,
                governanceFactoryData: p.governanceFactoryData,
                poolInitializer: p.poolInitializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: p.liquidityMigrator,
                liquidityMigratorData: p.liquidityMigratorData,
                integrator: p.integrator,
                salt: p.salt,
                creator: p.creator,
                creatorVestingAmount: p.creatorVestingAmount,
                creatorVestingStart: p.creatorVestingStart,
                creatorVestingDuration: p.creatorVestingDuration,
                presaleDistributor: address(this),
                presaleVestingAmount: p.presaleVestingAmount
            })
        );
        uint256 totalAssetNeeded;
        uint256 length = participants.length;
        for (uint256 i; i < length; ++i) {
            PresaleParticipant calldata sp = participants[i];
            require(p.numeraire != address(0), "native numeraire unsupported");
            ERC20(p.numeraire).safeTransferFrom(sp.account, address(this), sp.quoteAmount);
            uint256 assetOut = (sp.quoteAmount * 1e18) / priceWad;
            totalAssetNeeded += assetOut;
        }
        uint256 availablePresale = ERC20(asset).balanceOf(address(this));
        if (totalAssetNeeded > availablePresale) revert PresaleOverAllocation();
        for (uint256 i; i < length; ++i) {
            PresaleParticipant calldata sp = participants[i];
            uint256 assetOut = (sp.quoteAmount * 1e18) / priceWad;
            require(vestingFactory != address(0), "vesting factory not set");
            ERC20(asset).safeTransfer(vestingFactory, assetOut);
            address vestingAddr = IVestingFactory(vestingFactory).create(
                asset,
                sp.account,
                uint128(assetOut),
                vestStart,
                vestDuration
            );
            emit PresaleVestingCreated(asset, sp.account, vestingAddr, assetOut);
        }
        if (p.numeraire != address(0)) {
            uint256 totalQuote = ERC20(p.numeraire).balanceOf(address(this));
            if (totalQuote > 0) {
                ERC20(p.numeraire).safeTransfer(quoteRecipient, totalQuote);
                emit QuoteForwarded(p.numeraire, quoteRecipient, totalQuote);
            }
        }
    }
}
