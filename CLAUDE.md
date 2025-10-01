# NoiceLaunchpad Implementation Guide

## Overview
Multi-phase implementation of NoiceLaunchpad using Doppler multicurve Uni V4 for pool initialization. All tokens launched through this platform are paired with NOICE token.

## Important Addresses (Base Mainnet)
- **NOICE Token**: `0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69`
- **Sablier Lockup Linear**: `0xC2Da366fD67423b500cDF4712BdB41d0995b0794`
- **Pool Manager V4**: Configured in deployment scripts
- **Universal Router**: Configured in deployment scripts

## Development Phases

### Phase 1: Creator Vesting ✅ (CURRENT)
**Status**: In Development

#### Features:
- ✅ 45% of total supply allocated to creator with linear vesting
- ✅ Integration with Sablier V2 for vesting streams
- ✅ TeamGovernanceFactory for proper fund routing
- ✅ Remaining 55% available for token sale/liquidity

#### Implementation Details:
- Contract: `src/NoiceLaunchpadBundler.sol`
- Interface: `src/interfaces/ISablierLockup.sol`
- Tests: `test/unit/NoiceLaunchpadBundler.t.sol`

#### Vesting Configuration:
- Linear vesting over configurable period
- Optional cliff period support
- Cancelable and transferable options
- Automatic stream creation on token launch

### Phase 2: Presale with NOICE Locking ✅ (COMPLETED)
**Status**: Implemented

#### Features:
- ✅ Participants provide NOICE tokens to participate in presale
- ✅ Pro-rata allocation based on NOICE amounts
- ✅ Automatic vesting streams created for participants via Sablier
- ✅ Support for up to 100 participants per launch
- ✅ Configurable vesting schedules per participant

#### Implementation Details:
- Contract: `src/NoiceLaunchpad.sol` (extended from Phase 1)
- Struct: `PresaleParticipant` with locked address, NOICE amount, and vesting params
- Tests: `test/unit/NoiceLaunchpadSimple.t.sol`

#### Presale Flow:
1. Participants approve NoiceLaunchpad to spend their NOICE tokens
2. During token launch, contract collects NOICE from all participants via `transferFrom`
3. Single swap executed: total NOICE → newly launched token (via UniversalRouter)
4. Tokens distributed proportionally to participants based on their NOICE contribution
5. Each participant receives vested tokens via Sablier streams with custom schedules

#### Key Functions:
```solidity
bundleWithCreatorVesting(BundleWithVestingParams, PresaleParticipant[])
_executePresale(asset, participants, presaleCommands, presaleInputs)
_createPresaleVestingStream(asset, recipient, amount, start, end)
```

#### Security Features:
- Max 100 participants per launch
- Validates vesting timestamps for each participant
- Handles zero amounts gracefully
- Pro-rata calculation prevents rounding exploitation

### Phase 3: LP Position Minting 🔄 (PLANNED)
**Status**: Not Started

#### Planned Features:
- Mint LP positions at specific tick ranges for creator
- Configure multiple price discovery slugs
- Support for concentrated liquidity positions
- Integration with UniswapV4 multicurve hook
- Creator receives NOICE rewards when positions are reached

#### LP Strategy:
1. Creator defines tick ranges for LP positions
2. Positions minted with launched token liquidity
3. As price reaches certain ticks, creator earns NOICE
4. Incentivizes long-term price stability

## Testing Guidelines

### Environment Setup
```bash
# Fork Base mainnet for testing
forge test --fork-url $BASE_MAINNET_RPC_URL --fork-block-number <recent_block>
```

### Using Cheatcodes for Token Distribution
```solidity
// Give test user NOICE tokens
deal(0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69, testUser, 1000000e18);

// Give test user ETH
vm.deal(testUser, 100 ether);

// Impersonate user for transactions
vm.startPrank(testUser);
// ... perform actions
vm.stopPrank();
```

### Test Coverage Requirements
- [ ] Creator vesting allocation (45%)
- [ ] Sablier stream creation and parameters
- [ ] TeamGovernanceFactory integration
- [ ] Edge cases (invalid timestamps, zero amounts)
- [ ] Gas optimization tests
- [ ] Security considerations

## Contract Architecture

### NoiceLaunchpadBundler
Main contract orchestrating token launch with vesting:
- Inherits bundling functionality
- Overrides allocation to implement 45% vesting
- Creates Sablier streams for vesting
- Integrates with TeamGovernanceFactory

### Key Functions
```solidity
bundleWithCreatorVesting(CreateParams, VestingParams)
_createCreatorVestingStream(address, address, uint256, uint40, uint40)
_calculateVestingAllocation(uint256) // Returns 45% of supply
```

## Security Considerations
1. Validate all timestamp parameters
2. Ensure sufficient token balance before vesting
3. Verify Sablier stream creation success
4. Protect against reentrancy in token transfers
5. Validate creator address is not zero

## Gas Optimization
- Batch operations where possible
- Use immutable variables for addresses
- Optimize struct packing
- Minimize storage writes

## Deployment Checklist
- [ ] Deploy TeamGovernanceFactory
- [ ] Deploy NoiceLaunchpadBundler
- [ ] Verify contracts on BaseScan
- [ ] Test with small amounts first
- [ ] Monitor initial launches

## Future Enhancements
- Dynamic vesting schedules
- Multiple vesting recipients
- Governance token integration
- Advanced LP strategies
- Cross-chain launches

## References
- [Sablier V2 Docs](https://docs.sablier.com)
- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4)
- [Base Network Docs](https://docs.base.org)