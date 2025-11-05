# Noice Launchpad Contracts 
[Noice](https://noice.so) is a permissioned launchpad built on top of [Doppler Multicurve](https://doppler.lol/multicurve.pdf) and Uniswap V4.


## Acknowledgement

This codebase is a fork of [Doppler](https://github.com/whetstoneresearch/doppler) at commit [`204d121`](https://github.com/whetstoneresearch/doppler/commit/204d1217c9a633cfe1f9b8da63feb649d0a9aa04).
The NoiceLaunchpad currently extends Doppler's Multicurve contracts and hence forking from the multicurve contracts have been helpful with tests and scripting.


## Core Features

  ### 1. Multicurve

  [Doppler's Multicurve](https://www.doppler.lol/multicurve.pdf) is a liquidity allocation strategy that stacks liquidity in tick ranges on top of each other to form a curve where liquidity in any given tick range is strictly increasing. This design significantly increases the cost of acquiring tokens within those ranges compared to a constant liquidity position. By concentrating liquidity more densely as price increases, Multicurve creates a more efficient price discovery mechanism and provides better protection against sudden price movements.

  ### 2. Creator Vesting with Linear Lockup

  Noice Launchpad prioritizes creators by allocating them the highest portion of the token supply, secured through linear vesting schedules. This ensures creators remain aligned with the long-term success of their project while maintaining meaningful ownership. Creators also have the flexibility to delegate portions of their vested allocation to team members or collaborators, with the same vesting parameters applied to delegated amounts.

  ### 3. Prebuy Mechanism with Vesting

  The launchpad implements a prebuy mechanism that allows early participants to commit quote tokens (i.e. NOICE) before the token launch. Once the token is launched, the launchpad automatically executes purchases at the earliest price range on
  behalf of prebuy participants. These acquired tokens are then distributed to participants with vesting schedules, incentivizing early support and promoting long term holding.

  ### 4. Single-Sided Liquidity Positions (SSLPs)

  The launchpad supports single-sided liquidity positions that enable creators to raise additional capital as
  their token appreciates. Creators can place their launched tokens in out-of-range liquidity positions at
  higher price points. As the token price crosses these milestones and enters the liquidity ranges, the tokens are gradually sold for the quote token, providing creators with progressive funding tied directly to their token's price progression.
  
### Launch Flow

```
┌─────────────────────────────────────────┐
│  1. Create token + Doppler multicurve   │
│     Uniswap v4 pool (NOICE as quote)    │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  2. Allocate tokens to create           │
│     NOICE LP unlock positions           │
│     (SSL: out-of-range positions that   │
│      unlock NOICE when crossed)         │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  3. Allocate tokens for creator         │
│     allocations (with Sablier vesting)  │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  4. Execute prebuy: swap NOICE → Token  │
│     and distribute with vesting         │
└─────────────────────────────────────────┘
```

## Core Contracts

- **NoiceLaunchpad**: Main orchestrator that coordinates all launch activities atomically in a single transaction 
- **Airlock**: Doppler's Airlock contract for token creation and pool initialization
- **MiniV4Manager**: Base contract providing Uniswap v4 position management
- **UniswapV4MulticurveInitializer**: Doppler's util that handles multicurve liquidity initialization
- **UniversalRouter**: Executes token swaps for the prebuy mechanism
- **Sablier**: Manages all vesting streams for creators and prebuy participants

### Contract Architecture 

```mermaid
classDiagram
    class NoiceLaunchpad {
        +address owner
        +IPoolManager poolManager
        +Airlock airlock
        +IUniversalRouter router
        +ISablierLockup sablierLockup
        +ISablierBatchLockup sablierBatchLockup
        +mapping assetCreators
        +mapping sablierStreams
        +mapping noiceLpUnlockPositions
        +mapping noiceLpUnlockPositionWithdrawn
        +bundleWithCreatorVesting()
        +withdrawNoiceLpUnlockPosition()
        +cancelVestingStreams()
        +sweep()
        +execute()
        +getNoiceLpUnlockPositions()
        +getNoiceLpUnlockPositionCount()
        -_initiateCreatorVesting()
        -_executeNoicePrebuy()
        -_createNoiceLpUnlockPositions()
    }

    class MiniV4Manager {
        +IPoolManager poolManager
        #_mint()
        #_burn()
    }

    class OwnableRoles {
        +onlyOwner()
        +onlyRoles()
        +onlyRolesOrOwner()
        +grantRoles()
        +revokeRoles()
        +hasAllRoles()
    }

    class Airlock {
        +create()
        +getAssetData()
    }

    class UniswapV4MulticurveInitializer {
        +getState()
        +createMulticurve()
    }

    NoiceLaunchpad --|> MiniV4Manager
    NoiceLaunchpad --|> OwnableRoles
    NoiceLaunchpad --> Airlock
    NoiceLaunchpad --> UniswapV4MulticurveInitializer
```

## Token Allocation and Distribution Details

### Allocation at Launch

```mermaid
graph TB
    Start[100B Total Supply] --> Split{Allocation Split}
    
    Split -->|40%| MC[40B Public Curves]
    Split -->|15%| SSL[15B SSL]
    Split -->|10%| Prebuy[10B Prebuy]
    Split -->|35%| Team[35B Team/Creator]
    
    MC --> MC0[10B Curve 0<br/>$200K-$250K]
    MC --> MC1A[4B Curve 1A<br/>$250K-$1M]
    MC --> MC1B[6B Curve 1B<br/>$500K-$1M]
    MC --> MC2A[1.5B Curve 2A<br/>$1M-$2M]
    MC --> MC2B[1.5B Curve 2B<br/>$1.5M-$2M]
    MC --> MC3[17B Curve 3<br/>$2M-$1.5B]
    
    SSL --> SSL1[3.85B SSL1<br/>$252K-$2.5M]
    SSL --> SSL2[4.46B SSL2<br/>$2.5M-$5M]
    SSL --> SSL3[4.24B SSL3<br/>$5M-$10M]
    SSL --> SSL4[2.45B SSL4<br/>$10M-$15M]
    
    Prebuy --> PB[10B<br/>1 year vest]
    
    Team --> Team1[30B Vested<br/>12 months]
    Team --> Team2[5B Unlocked<br/>Immediate]
    
```

### Circulation Over Time

**Immediate Circulation (t=0): 45B (45%)**
- 40B public curve positions
- 5B creator unlocked

**Progressive Unlock (t=0 to t=12mo): 40B (40%)**
- 10B prebuy (linear vest over 12 months)
- 30B creator (linear vest over 12 months)

**Price-Dependent Unlock: 15B (15%)**
- SSL positions unlock as price rises
- 4 tranches from $252K to $15M market cap
- Converted from $TOKEN → NOICE as positions cross

### Token Destination Flow

```mermaid
flowchart LR
    subgraph "Launch"
        LP[Launchpad Contract]
    end
    
    subgraph "Immediate Recipients"
        Pool[Uniswap V4 Pool<br/>40B multicurve]
        SSLPos[SSL Positions<br/>15B out-of-range]
    end
    
    subgraph "Vested Recipients"
        Creator[Creator Wallet<br/>30B + 5B streams]
        Syndicate[Syndicate Multisig<br/>5B stream]
        Ecosystem[Ecosystem Fund<br/>5B stream]
    end
    
    subgraph "Future Claims"
        Escrow[SSLP Escrow<br/>SSL unlocks]
    end
    
    LP -->|40B| Pool
    LP -->|15B| SSLPos
    LP -->|35B| Creator
    LP -->|5B| Syndicate
    LP -->|5B| Ecosystem
    
    SSLPos -.->|when crossed| Escrow
    Escrow -.->|claimable| Creator
```

## Multicurve Liquidity Details

### Curve Positions (40B Total)

| Curve | Amount | FDV Range | Ticks | Purpose |
|-------|---------|-----------|--------|---------|
| Curve 0 | 10B | $200K-$250K | -49980 to -47760 | Prebuy liquidity |
| Curve 1A | 4B | $250K-$1M | -47760 to -33900 | Initial public liquidity |
| Curve 1B | 6B | $500K-$1M | -40860 to -33900 | Overlapping depth |
| Curve 2A | 1.5B | $1M-$2M | -33900 to -27000 | Growth phase |
| Curve 2B | 1.5B | $1.5M-$2M | -29880 to -27000 | Overlapping growth |
| Curve 3 | 17B | $2M-$1.5B | -27000 to 39240 | Late stage depth |

### Curve Shares (out of 1e18)

```solidity
Curve 0:  200000000000000000  (20.0% of 50B = 10B)
Curve 1A:  80000000000000000  (8.0% of 50B = 4B)
Curve 1B: 120000000000000000  (12.0% of 50B = 6B)
Curve 2A:  30000000000000000  (3.0% of 50B = 1.5B)
Curve 2B:  30000000000000000  (3.0% of 50B = 1.5B)
Curve 3:  340000000000000000  (34.0% of 50B = 17B)
Total:    800000000000000000  (80% = 40B public curves)
```

Note: The remaining 20% (10B) comes from prebuy participants filling Curve 0.

### Liquidity Distribution Visualization

```mermaid
graph LR
    subgraph "Price Ranges"
        C0[Curve 0<br/>$200K-$250K<br/>10B tokens]
        C1[Curves 1A+1B<br/>$250K-$1M<br/>10B tokens]
        C2[Curves 2A+2B<br/>$1M-$2M<br/>3B tokens]
        C3[Curve 3<br/>$2M-$1.5B<br/>17B tokens]
    end
    
    C0 -->|price increases| C1
    C1 -->|price increases| C2
    C2 -->|price increases| C3
    
```

### Valley Effect Analysis

The overlapping curves create "valley effects" at specific market cap milestones:

1. **$500K-$1M Valley:** 10B tokens (Curves 1A + 1B)
   - Enhanced liquidity depth
   - Reduced slippage for large trades
   - Price stability zone

2. **$1.5M-$2M Valley:** 3B tokens (Curves 2A + 2B)
   - Secondary accumulation zone
   - Controlled price discovery
   - Reduced price manipulation

### Prebuy + Vesting

#### Participant Structure

**Syndicate Multisig**
- Amount: ~191M NOICE (50% of prebuy)
- Vesting: 1 year linear
- Receives: 5B ORACLE tokens vested

**Ecosystem Fund Multisig**
- Amount: ~191M NOICE (50% of prebuy)
- Vesting: 1 year linear
- Receives: 5B ORACLE tokens vested

#### Execution Flow

```mermaid
sequenceDiagram
    participant SM as Syndicate Multisig
    participant EFM as Ecosystem Fund Multisig
    participant NL as Noice Launchpad
    participant UR as Universal Router
    participant SAB as Sablier

    Note over SM,EFM: Pre-launch approvals
    
    SM->>NL: Approve NOICE
    EFM->>NL: Approve NOICE
    
    Note over NL: During launch execution
    
    NL->>SM: TransferFrom NOICE
    NL->>EFM: TransferFrom NOICE
    
    NL->>UR: Swap NOICE → ORACLE
    UR-->>NL: ORACLE tokens (10B)
    
    Note over NL: Calculate pro-rata distribution
    
    NL->>SAB: Create vesting streams
    SAB-->>SM: Vested ORACLE (5B)
    SAB-->>EFM: Vested ORACLE (5B)
```

## Creator Allocation + Vesting

### Allocation Breakdown

**Creator Vesting (35B tokens)**
- 30B vested over 12 months
- 5B unlocked immediately
- All streams created via Sablier batch
- Recipient: Creator Privy Wallet

### Vesting Structure

```solidity
struct CreatorAllocation {
    address recipient;        // Creator Privy Wallet
    uint256 amount;          // 30B or 5B
    uint40 lockStartTimestamp;
    uint40 lockEndTimestamp; // +12 months or immediate
}
```

## Single Side Liquidity Positions System

### SSL Position Lifecycle

```mermaid
stateDiagram-v2
    [*] --> OutOfRange: Position created
    
    OutOfRange --> InRange: Price crosses lower tick
    
    state InRange {
        [*] --> Accumulating
        Accumulating --> ConvertingOracle: Continuous
        ConvertingOracle --> AccruingFees: Continuous
        AccruingFees --> [*]
    }
    
    InRange --> FullyCrossed: Price crosses upper tick
    
    FullyCrossed --> PendingWithdrawal: All ORACLE → NOICE
    PendingWithdrawal --> Withdrawn: Executor calls withdraw
    Withdrawn --> InEscrow: NOICE transferred
    InEscrow --> Claimed: Creator claims
    Claimed --> [*]
```

### Withdrawal Process

**Monitoring (Automated)**
- Track current pool tick
- Identify fully crossed positions
- Alert when withdrawal available

**Execution (Executor Role)**
```solidity
withdrawNoiceLpUnlockPosition(
    oracleAddress,
    trancheId
)
```

## Liquidity Efficiency Analysis

### Constant vs Multicurve Comparison

If we used constant liquidity from $250K-$1.5B instead of multicurve:

| Range | Constant Supply | Multicurve Supply | Efficiency |
|-------|-----------------|-------------------|------------|
| $250K-$1M | 20.3B | 10B | 49% |
| $1M-$2M | 5.9B | 3B | 51% |
| $2M-$1.5B | 13.8B | 17B | 123% |

**Key Benefits:**
- Uses ~50% fewer tokens in early ranges
- Preserves more tokens for growth phases
- Creates "valley effects" for accumulation zones
- Improves capital efficiency by 2x in critical ranges

## Access Control Matrix

| Function | Owner | Executor | Creator | Notes |
|----------|-------|----------|---------|-------|
| `bundleWithCreatorVesting()` | ✓ | ✓ | ✗ | Atomic launch |
| `withdrawNoiceLpUnlockPosition()` | ✓ | ✓ | ✗ | Claim SSL NOICE |
| `cancelVestingStreams()` | ✓ | ✗ | ✗ | Emergency only |
| `sweep()` | ✓ | ✗ | ✗ | Token recovery |
| `execute()` | ✓ | ✗ | ✗ | Arbitrary calls |
| `grantRoles()` | ✓ | ✗ | ✗ | Role management |

## Security

### Audit

NoiceLaunchpad has been audited by [**Pashov Audit Group**](https://pashov.com).

- **Audit Period**: October 10, 2025 - October 13, 2025
- **Audited Commit**: [`4d7e8c2`](https://github.com/noiceengg/noice-launchpad/commit/4d7e8c22cd7bb7404c0747da85a8c21878e41b3a)
- **Audit Report**: attached [here](audits/NoiceLaunchpad-security-review_2025-10-11.pdf)
- **Remediation PR**: [Audit Fixes](https://github.com/noiceengg/noice-launchpad/pull/1)
