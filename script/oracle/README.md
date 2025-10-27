# Oracle Launch Scripts

Complete suite of scripts for deploying and managing Oracle token launches on Base using the NoiceLaunchpad system.

## Directory Structure

```
script/oracle/
├── deploy/           # Launchpad deployment and setup
├── launch/           # Token launch scripts
└── misc/            # Utilities and management tools
    ├── mine/        # Address mining tools
    ├── sslp/        # SSL position management
    └── utils/       # General utilities
```

## Quick Start

### 1. Deploy NoiceLaunchpad

```bash
# Option A: Deploy with default address
forge script script/oracle/deploy/DeployNoiceLaunchpad.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY --verify

# Option B: Mine for vanity address first
DEPLOYER_ADDRESS=$DEPLOYER \
START_PATTERN=0 \
END_PATTERN=69 \
forge script script/oracle/misc/mine/MineNoiceLaunchpadSalt.s.sol --ffi

# Then deploy with mined salt (update script with salt)
```

### 2. Grant Executor Role

```bash
# Update LAUNCHPAD address in script first
forge script script/oracle/deploy/GrantExecutorRole.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY
```

### 3. Mine Oracle Token Address

```bash
# Mine for address ending in 69 and < NOICE
forge script script/oracle/misc/mine/MineOracleSalt.s.sol --ffi

# Save the output
export ORACLE_SALT=0x...
```

### 4. Launch Oracle Token

```bash
# Launch with 30B creator vesting, 5B unlocked, 10B prebuy, 15B SSL, 40B public
forge script script/oracle/launch/LaunchOracle.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY

# Save the token address
export TOKEN_ADDRESS=0x...
```

### 5. Execute Trades (Optional)

```bash
# Buy 30B tokens to cross SSL positions
forge script script/oracle/misc/sslp/ExecuteTrades.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY
```

### 6. Unlock SSL Positions

```bash
# Unlock crossed SSL positions and collect fees
forge script script/oracle/misc/sslp/UnlockPositions.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY
```

### 7. Collect Multicurve Fees

```bash
# Collect trading fees from multicurve positions
forge script script/oracle/misc/sslp/CollectFees.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY
```

### 8. Unlock Vesting

```bash
# Unlock creator and prebuy vesting streams
export RECIPIENT_ADDRESS=0x...
export STREAM_IDS="15253,15254"

forge script script/oracle/misc/utils/UnlockVesting.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY
```

## Scripts Reference

### Deploy

#### `DeployNoiceLaunchpad.s.sol`
Deploys NoiceLaunchpad contract on Base Mainnet.

**Outputs:**
- NoiceLaunchpad address

**Next:** Run `GrantExecutorRole.s.sol`

---

#### `GrantExecutorRole.s.sol`
Grants executor role to deployer address.

**Configuration:**
- Update `LAUNCHPAD` constant with deployed address

**Requirements:**
- Deployer must be launchpad owner

---

### Launch

#### `LaunchOracle.s.sol`
Launches Oracle token with full configuration.

**Environment Variables:**
- `ORACLE_SALT` - Salt from MineOracleSalt.s.sol (required)

**Configuration:**
- Update `LAUNCHPAD` constant with deployed address

**Token Distribution (100B total):**
- **Creator:** 35B (30B vested 24mo, 5B vested 1d)
- **Prebuy:** 10B (exact output, 1yr vesting, max 200M NOICE)
- **SSL:** 15B (4 tranches across $250K-$15M)
  - SSL1: 3.85B @ $250K-$2.5M
  - SSL2: 4.46B @ $2.5M-$5M
  - SSL3: 4.24B @ $5M-$10M
  - SSL4: 2.45B @ $10M-$15M
- **Public:** 40B (multicurve liquidity)

**Outputs:**
- Token address (must end in 0x69 and < NOICE)
- Creator vesting stream IDs
- Prebuy vesting stream ID

**Next:** Set `TOKEN_ADDRESS` env var

---

### Misc/Mine

#### `MineOracleSalt.s.sol`
Mines CREATE2 salt for Oracle token address with desired properties.

**Requirements:**
- Address must end in `0x69`
- Address must be < NOICE (`0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69`)

**How it works:**
- Uses `cast create2` via FFI (fast Rust implementation)
- Searches for addresses starting with `0` (always < 0x9C)
- Finds first match ending in `69`

**Outputs:**
- `ORACLE_SALT` - Use in LaunchOracle.s.sol

**Example Output:**
```
Salt: 0xbb609bed8711e2549a2a2f8edda8e3c562768058fef77aa52af7e0d283d4559a
Address: 0x0c2Af64cbF45f936D411668F6a630F50Af9EF969
```

---

#### `MineNoiceLaunchpadSalt.s.sol`
Mines CREATE2 salt for NoiceLaunchpad deployment address.

**Environment Variables:**
- `DEPLOYER_ADDRESS` - Address that will deploy (required)
- `START_PATTERN` - Address prefix (default: "0")
- `END_PATTERN` - Address suffix (optional)

**Examples:**

```bash
# Mine for 0x0...69
DEPLOYER_ADDRESS=0x420ae9b2f9a63FCB809c5fd0f9bf01B137792169 \
START_PATTERN=0 \
END_PATTERN=69 \
forge script script/oracle/misc/mine/MineNoiceLaunchpadSalt.s.sol --ffi

# Mine for 0xdead...beef
DEPLOYER_ADDRESS=0x420ae9b2f9a63FCB809c5fd0f9bf01B137792169 \
START_PATTERN=dead \
END_PATTERN=beef \
forge script script/oracle/misc/mine/MineNoiceLaunchpadSalt.s.sol --ffi
```

**Outputs:**
- Salt and predicted address
- Deployment code snippet

---

### Misc/SSLP

#### `ExecuteTrades.s.sol`
Executes trades to buy Oracle tokens and cross SSL positions.

**Environment Variables:**
- `TOKEN_ADDRESS` - Oracle token address (required)

**Configuration:**
- `TOKENS_TO_SWAP` - Amount to buy (default: 30B)

**What it does:**
- Approves NOICE to Permit2 and Universal Router
- Executes exact output swap via Uniswap V4
- Reports NOICE spent and final tick

**Example Output:**
```
NOICE spent: 2255230575 (2.26B NOICE)
Token received: 30000000000 (30B tokens)
Final tick: -18635
```

**Next:** Run `UnlockPositions.s.sol`

---

#### `UnlockPositions.s.sol`
Unlocks SSL LP positions and collects fees.

**Environment Variables:**
- `TOKEN_ADDRESS` - Oracle token address (required)

**Configuration:**
- Update `LAUNCHPAD` constant

**What it does:**
- Iterates through all 4 SSL positions
- Withdraws liquidity and collects fees
- Reports tokens and NOICE gained per position

**Example Output:**
```
Position 0 unlocked: +92.4M NOICE
Position 1 unlocked: +488.2M NOICE
Position 2 unlocked: 0 (not crossed)
Position 3 unlocked: 0 (not crossed)
Total NOICE gained: 580.6M
```

**Next:** Run `CollectFees.s.sol`

---

#### `CollectFees.s.sol`
Collects trading fees from multicurve positions.

**Environment Variables:**
- `TOKEN_ADDRESS` - Oracle token address (required)

**What it does:**
- Collects fees from all multicurve positions
- Distributes to beneficiaries (95% creator, 5% protocol)

**Example Output:**
```
Fees collected:
  Fees0: 123.45M tokens
  Fees1: 678.90M NOICE
```

---

### Misc/Utils

#### `UnlockVesting.s.sol`
Withdraws from Sablier vesting streams (creator & prebuy).

**Environment Variables:**
- `RECIPIENT_ADDRESS` - Address receiving vested tokens (required)
- `STREAM_IDS` - Comma-separated stream IDs (required)

**What it does:**
- Validates stream recipients match expected address
- Withdraws maximum available amount from each stream
- Reports total withdrawn

**Example:**
```bash
# Unlock both creator vesting streams
export RECIPIENT_ADDRESS=0x420ae9b2f9a63FCB809c5fd0f9bf01B137792169
export STREAM_IDS="15253,15254"

forge script script/oracle/misc/utils/UnlockVesting.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --broadcast --private-key $PRIVATE_KEY
```

**Stream ID Sources:**
- Creator vesting: From `LaunchOracle.s.sol` logs
- Prebuy vesting: From `LaunchOracle.s.sol` logs

**Features:**
- Reusable for any recipient address
- Handles multiple streams in one transaction
- Validates all streams have same asset token

---

## Token Economics

### Oracle Token Distribution (100B Total Supply)

| Allocation | Amount | Percentage | Vesting | Notes |
|------------|--------|------------|---------|-------|
| Creator Vesting | 30B | 30% | 24 months | Linear unlock |
| Creator Unlocked | 5B | 5% | 1 day | Immediate access |
| Prebuy | 10B | 10% | 12 months | Exact output swap |
| SSL Positions | 15B | 15% | Tick-based | 4 tranches |
| Public Liquidity | 40B | 40% | - | Multicurve |

### SSL Tranches

| Tranche | Amount | Tick Range | Market Cap Range | NOICE at Range |
|---------|--------|------------|------------------|----------------|
| SSL1 | 3.85B | -49500 to -25500 | $252K - $2.5M | ~$50K |
| SSL2 | 4.46B | -25500 to -18420 | $2.5M - $5M | ~$157K |
| SSL3 | 4.24B | -18420 to -11340 | $5M - $10M | ~$300K |
| SSL4 | 2.45B | -11340 to -6840 | $10M - $15M | ~$300K |

**Total SSL Unlock Value:** ~$807K NOICE

### Multicurve Configuration

**Fee:** 2% (20000)

**Curves:**
1. **Early (12.5%)**: 5B tokens across 20 positions from $250K to $998K
2. **Late (87.5%)**: 35B tokens in single position from $998K to $1.5B

**Fee Distribution:**
- Protocol: 5%
- Creator: 95%

---

## Contract Addresses (Base Mainnet)

| Contract | Address |
|----------|---------|
| Airlock | `0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12` |
| NOICE Token | `0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69` |
| Token Factory | `0x4225C632b62622Bd7B0A3eC9745C0a866Ff94F6F` |
| Governance Factory | `0x40Bcb4dDA3BcF7dba30C5d10c31EE2791ed9ddCa` |
| Multicurve Initializer | `0xA36715dA46Ddf4A769f3290f49AF58bF8132ED8E` |
| Multicurve Hook | `0x3e342a06f9592459D75721d6956B570F02eF2Dc0` |
| NoOp Migrator | `0x6ddfED58D238Ca3195E49d8ac3d4cEa6386E5C33` |
| Pool Manager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Sablier Lockup | `0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B` |
| Sablier Batch Lockup | `0xC26CdAFd6ec3c91AD9aEeB237Ee1f37205ED26a4` |
| Doppler Owner | `0x21E2ce70511e4FE542a97708e89520471DAa7A66` |

---

## Testing on Tenderly

All scripts can be tested on Tenderly virtual testnets before mainnet deployment:

```bash
# Example Tenderly RPC
export TENDERLY_RPC=https://virtual.base.eu.rpc.tenderly.co/YOUR-ID

# Run any script
forge script script/oracle/launch/LaunchOracle.s.sol \
  --rpc-url $TENDERLY_RPC \
  --broadcast --private-key $PRIVATE_KEY
```

**Note:** Ensure test accounts are funded with NOICE for prebuy testing.

---

## Common Workflows

### Full Launch Workflow

```bash
# 1. Mine launchpad address (optional)
DEPLOYER_ADDRESS=$DEPLOYER START_PATTERN=0 END_PATTERN=69 \
forge script script/oracle/misc/mine/MineNoiceLaunchpadSalt.s.sol --ffi

# 2. Deploy launchpad
forge script script/oracle/deploy/DeployNoiceLaunchpad.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY --verify

# 3. Grant executor role
forge script script/oracle/deploy/GrantExecutorRole.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY

# 4. Mine oracle token address
forge script script/oracle/misc/mine/MineOracleSalt.s.sol --ffi
export ORACLE_SALT=0x...

# 5. Launch token
forge script script/oracle/launch/LaunchOracle.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY
export TOKEN_ADDRESS=0x...

# 6. Execute test trades (optional)
forge script script/oracle/misc/sslp/ExecuteTrades.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY

# 7. Unlock SSL positions
forge script script/oracle/misc/sslp/UnlockPositions.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY

# 8. Collect fees
forge script script/oracle/misc/sslp/CollectFees.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY

# 9. Unlock vesting (when time passes)
RECIPIENT_ADDRESS=$DEPLOYER STREAM_IDS="15253,15254" \
forge script script/oracle/misc/utils/UnlockVesting.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY
```

### SSL Position Management

```bash
# Check which positions can be unlocked by executing a small trade first
TOKEN_ADDRESS=0x... \
forge script script/oracle/misc/sslp/ExecuteTrades.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY

# Unlock crossed positions
TOKEN_ADDRESS=0x... \
forge script script/oracle/misc/sslp/UnlockPositions.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY

# Collect accumulated fees
TOKEN_ADDRESS=0x... \
forge script script/oracle/misc/sslp/CollectFees.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY
```

### Vesting Management

```bash
# Check vesting streams (query Sablier)
cast call $SABLIER_LOCKUP "withdrawableAmountOf(uint256)(uint128)" $STREAM_ID \
  --rpc-url $BASE_MAINNET_RPC_URL

# Unlock specific streams
RECIPIENT_ADDRESS=0x... STREAM_IDS="15253,15254,15255" \
forge script script/oracle/misc/utils/UnlockVesting.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY
```

---

## Troubleshooting

### "Invalid position index"
- **Cause:** Using wrong LAUNCHPAD address
- **Fix:** Update `LAUNCHPAD` constant in script to match deployed address

### "ERC20InsufficientBalance"
- **Cause:** Insufficient NOICE balance for prebuy
- **Fix:** Fund deployer with at least 200M NOICE tokens

### "ORACLE_SALT not set"
- **Cause:** Missing environment variable
- **Fix:** Run `MineOracleSalt.s.sol` first and export the salt

### "Stream recipient mismatch"
- **Cause:** Wrong RECIPIENT_ADDRESS for stream
- **Fix:** Use correct recipient address from launch logs

### Mining takes too long
- **Cause:** Difficult pattern to find
- **Fix:** Use simpler patterns (e.g., just start pattern, no end pattern)

---

## Security Notes

1. **Private Keys:** Never commit private keys. Use environment variables or hardware wallets.
2. **Salt Verification:** Always verify mined addresses before deployment.
3. **Test First:** Use Tenderly virtual testnets for testing before mainnet.
4. **Vesting Validation:** Verify stream recipients and amounts before unlocking.
5. **Fee Collection:** Only owner can collect fees - verify ownership first.

---

## Support

For issues or questions:
- Check transaction logs for detailed error messages
- Verify all environment variables are set correctly
- Ensure contract addresses match network (Base Mainnet)
- Test on Tenderly first for complex operations
