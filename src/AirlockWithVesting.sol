 
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { DERC20 } from "src/DERC20.sol";
import { Airlock, ModuleState, AssetData } from "src/Airlock.sol";
import { IVestingFactory } from "src/vesting/IVestingFactory.sol";

struct CreateWithVestingParams {
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

    address creator;
    uint256 creatorVestingAmount;
    uint64 creatorVestingStart;
    uint64 creatorVestingDuration;

    address presaleDistributor;
    uint256 presaleVestingAmount;
}
contract AirlockWithVesting is Airlock {
    using SafeTransferLib for ERC20;
    constructor(address owner_) Airlock(owner_) {}

    event Create(address asset, address indexed numeraire, address initializer, address poolOrHook);
    event CreatorVestingDeployed(address indexed asset, address vesting, address indexed creator, uint256 amount);
    event PresaleReserved(address indexed asset, address indexed distributor, uint256 amount);

    address public vestingFactory;

    function setVestingFactory(address factory) external onlyOwner {
        vestingFactory = factory;
    }

    function createWithVesting(
        CreateWithVestingParams calldata p
    )
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        _validateModuleState(address(p.tokenFactory), ModuleState.TokenFactory);
        _validateModuleState(address(p.governanceFactory), ModuleState.GovernanceFactory);
        _validateModuleState(address(p.poolInitializer), ModuleState.PoolInitializer);
        _validateModuleState(address(p.liquidityMigrator), ModuleState.LiquidityMigrator);

        asset = p.tokenFactory.create(p.initialSupply, address(this), address(this), p.salt, p.tokenFactoryData);
        (governance, timelock) = p.governanceFactory.create(asset, p.governanceFactoryData);

        uint256 reserved = p.creatorVestingAmount + p.presaleVestingAmount;
        uint256 toSell = p.numTokensToSell;
        if (reserved >= toSell) {
            toSell = 0;
        } else {
            unchecked { toSell = toSell - reserved; }
        }

        ERC20(asset).approve(address(p.poolInitializer), toSell);
        pool = p.poolInitializer.initialize(asset, p.numeraire, toSell, p.salt, p.poolInitializerData);

        migrationPool = p.liquidityMigrator.initialize(asset, p.numeraire, p.liquidityMigratorData);
        DERC20(asset).lockPool(migrationPool);

        uint256 excessAsset = ERC20(asset).balanceOf(address(this));

        if (p.creatorVestingAmount > 0) {
            require(excessAsset >= p.creatorVestingAmount, "insufficient excess for creator vesting");
            require(vestingFactory != address(0), "vesting factory not set");
            ERC20(asset).safeTransfer(vestingFactory, p.creatorVestingAmount);
            address vestingAddr = IVestingFactory(vestingFactory).create(
                asset,
                p.creator,
                uint128(p.creatorVestingAmount),
                p.creatorVestingStart,
                p.creatorVestingDuration
            );
            excessAsset -= p.creatorVestingAmount;
            emit CreatorVestingDeployed(asset, vestingAddr, p.creator, p.creatorVestingAmount);
        }

        if (p.presaleVestingAmount > 0) {
            require(excessAsset >= p.presaleVestingAmount, "insufficient excess for presale");
            ERC20(asset).safeTransfer(p.presaleDistributor, p.presaleVestingAmount);
            excessAsset -= p.presaleVestingAmount;
            emit PresaleReserved(asset, p.presaleDistributor, p.presaleVestingAmount);
        }

        if (excessAsset > 0) {
            ERC20(asset).safeTransfer(timelock, excessAsset);
        }

        getAssetData[asset] = AssetData({
            numeraire: p.numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: p.liquidityMigrator,
            poolInitializer: p.poolInitializer,
            pool: pool,
            migrationPool: migrationPool,
            numTokensToSell: p.numTokensToSell,
            totalSupply: p.initialSupply,
            integrator: p.integrator == address(0) ? owner() : p.integrator
        });

        emit Create(asset, p.numeraire, address(p.poolInitializer), pool);
    }

    function getTimelock(address asset) external view returns (address) {
        return getAssetData[asset].timelock;
    }
}
