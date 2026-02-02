# Semi-Async-Vault Architecture Documentation

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LOGARITHM ACP AGENT (Python Backend)                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                      SmartWrapperOperator (PollingRunner)                │   │
│  │  • Monitors pendingWithdrawals() and idleAssets()                       │   │
│  │  • Calls transmitAllocatedAssets() to sync PnL                          │   │
│  │  • Calls transmitDeallocatedAssets() to fulfill withdrawals             │   │
│  │  • Calls allocateAssets() to deploy new deposits                        │   │
│  └───────────────────────────────┬─────────────────────────────────────────┘   │
│                                  │                                              │
│  ┌───────────────────────────────▼─────────────────────────────────────────┐   │
│  │                    SmartWrapper (Python Contract Interface)              │   │
│  │  • transmit_allocated_assets(assets) → transmitAllocatedAssets()        │   │
│  │  • transmit_deallocated_assets(dealloc, remaining)                      │   │
│  │  • allocate_assets(assets) → allocateAssets()                           │   │
│  │  • get_idle_assets() / get_pending_withdrawals() / get_allocated_assets()│   │
│  └───────────────────────────────┬─────────────────────────────────────────┘   │
└──────────────────────────────────┼──────────────────────────────────────────────┘
                                   │ Web3 RPC Calls
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SEMI-ASYNC-VAULT (Solidity Smart Contracts)                  │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │              SmartAccountWrapper (extends SemiAsyncRedeemVault)         │   │
│  │                                                                         │   │
│  │   ROLES:                                                                │   │
│  │   └── owner: Admin controls (forceTransmit*, allocate*, setSmartAccount)│   │
│  │                                                                         │   │
│  │   STORAGE:                                                              │   │
│  │   ├── smartAccount: External address holding allocated assets           │   │
│  │   └── allocatedAssets: uint256 tracking deployed capital               │   │
│  └─────────────────────────────────┬───────────────────────────────────────┘   │
│                                    │ inherits                                   │
│  ┌─────────────────────────────────▼───────────────────────────────────────┐   │
│  │               SemiAsyncRedeemVault (abstract, extends ERC4626)          │   │
│  │                                                                         │   │
│  │   USER FUNCTIONS:                                                       │   │
│  │   ├── deposit() / withdraw() → Standard ERC4626                         │   │
│  │   ├── requestWithdraw(assets, receiver, owner) → bytes32 withdrawKey    │   │
│  │   ├── requestRedeem(shares, receiver, owner) → bytes32 withdrawKey      │   │
│  │   └── claim(withdrawKey) → Claim fulfilled request                      │   │
│  │                                                                         │   │
│  │   ASSET STATES:                                                         │   │
│  │   ├── idleAssets(): Available for immediate withdrawal                  │   │
│  │   ├── allocatedAssets(): Deployed in strategies                         │   │
│  │   ├── pendingWithdrawals(): User requests awaiting fulfillment          │   │
│  │   └── totalAssets(): idleAssets + allocatedAssets - pendingWithdrawals  │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                SmartAccountProxy (BeaconProxy)                          │   │
│  │   • Upgradeable proxy pattern using OpenZeppelin Beacon                 │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
                                   │ Asset Transfer
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           EXTERNAL SMART ACCOUNT (Zyfai)                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                         Zyfai Smart Account                             │   │
│  │   • Holds actual USDC allocated from wrapper                            │   │
│  │   • Executes yield strategies (external DeFi protocols)                 │   │
│  │   • request_withdraw(amount, recipient) → Returns assets to operator    │   │
│  │   • get_balance() → Current asset balance in account                    │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Contract Functions Reference

### 2.1 SemiAsyncRedeemVault (Abstract Base)

| Function | Visibility | Purpose |
|----------|------------|---------|
| **User Actions** |||
| `requestWithdraw(assets, receiver, owner)` | public | Request withdrawal; immediately fulfills from idle assets, queues remainder |
| `requestRedeem(shares, receiver, owner)` | public | Same as above but denominated in shares |
| `claim(withdrawKey)` | public | Claim assets from a fulfilled withdrawal request |
| `isClaimable(withdrawKey)` | view | Check if request can be claimed |
| `isClaimed(withdrawKey)` | view | Check if request was already claimed |
| **Views** |||
| `idleAssets()` | view | Assets immediately available (vault balance + claimable - obligations) |
| `pendingWithdrawals()` | view | Total unfulfilled user withdrawal requests |
| `allocatedAssets()` | view (virtual) | Assets deployed in external strategies |
| `totalAssets()` | view | Net asset value (idle + allocated - pending) |
| `maxWithdraw(owner)` | view | Min(user's assets, idle assets) |
| `maxRequestWithdraw(owner)` | view | User's total withdrawable assets |
| **Helpers** |||
| `cumulativeRequestedWithdrawalAssets()` | view | Lifetime total of requested withdrawals |
| `cumulativeClaimedAssets()` | view | Lifetime total of claimed assets |
| `getWithdrawKey(user, nonce)` | view | Compute withdrawal request identifier |

### 2.2 SmartAccountWrapper (Concrete Implementation)

| Function | Visibility | Modifier | Purpose |
|----------|------------|----------|---------|
| **Initialization** ||||
| `initialize(owner, smartAccount, token, name, symbol)` | public | initializer | Setup wrapper with owner and asset |
| `reinitialize(owner)` | public | reinitializer(2) | Upgrade re-initialization |
| **Smart Account Functions** ||||
| `transmitAllocatedAssets(assets)` | public | onlySmartAccount | Sync PnL: update `allocatedAssets` to match smart account balance |
| `transmitDeallocatedAssets(remaining)` | public | onlySmartAccount | Fulfill withdrawals: update accounting after deallocation |
| **Owner Functions** ||||
| `allocateAssets(assets)` | public | onlyOwner | Deploy idle assets to smart account |
| `setSmartAccount(address)` | public | onlyOwner | Update smart account address |
| `forceTransmitAllocatedAssets(assets)` | public | onlyOwner | Emergency PnL sync (bypasses deviation check) |
| `forceTransmitDeallocatedAssets(remaining)` | public | onlyOwner | Emergency withdrawal fulfillment |
| **Views** ||||
| `smartAccount()` | view | - | Address holding allocated assets |
| `pendingDeallocationAssets()` | pure | - | Always 0 (no async strategy unwinding) |
| `claimableFromStrategies()` | pure | - | Always 0 (no pending claims from strategies) |

---

## 3. Asset Flow Lifecycle

### 3.1 Deposit Flow
```
User → deposit(assets, receiver)
       │
       ├── ERC4626._deposit() mints shares
       ├── SmartAccountWrapper._deposit() calls _transferToSmartAccount(assets)
       │       └── allocatedAssets += assets
       │       └── asset.safeTransfer(smartAccount, assets)
       │
       └── Assets now in Zyfai Smart Account
```

### 3.2 Withdrawal Flow (Immediate Path)
```
User → requestWithdraw(assets, receiver, owner)
       │
       ├── Check: idleAssets() >= assets?
       │       └── YES: Immediately transfer, return bytes32(0)
       │
       └── Result: User receives assets, no pending request created
```

### 3.3 Withdrawal Flow (Async Path)
```
User → requestWithdraw(assets, receiver, owner)
       │
       ├── Check: idleAssets() >= assets?
       │       └── NO: Create WithdrawRequest, burn shares
       │
       └── pendingWithdrawals() increases by (assets - idleAssets)

═══════════════════════════════════════════════════════════════════════

Backend Polling Loop (SmartWrapperOperator):
       │
       ├── Detect: pendingWithdrawals() > 0
       ├── Call: smart_account.request_withdraw(amount, operator)
       ├── Wait: Assets arrive at operator's wallet
       └── Call: transmitDeallocatedAssets(deallocated, remaining)
               │
               ├── allocatedAssets = remaining
               └── asset.safeTransferFrom(operator, wrapper, deallocated)

═══════════════════════════════════════════════════════════════════════

User → claim(withdrawKey)
       │
       ├── Check: isClaimable(withdrawKey)
       │       └── cumulativeClaimedAssets + vaultBalance >= request.cumulative
       └── Transfer assets to receiver
```

---

## 4. Backend Integration Details

### 4.1 SmartWrapper Python Class

Location: `logarithm-acp-agent/contracts/smart_wrapper.py`

```python
class SmartWrapper(Vault):
    """Python interface to SmartAccountWrapper contract"""

    def __init__(self, chain_manager, address, operator_private_key, asset_decimals=6):
        # Inherits from Vault which extends Token → SmartContract
        self.smart_account = self.call_contract("smartAccount")
        self.operator = self.call_contract("operator")

    # === OPERATOR WRITE FUNCTIONS ===
    def transmit_allocated_assets(self, assets: Decimal) -> TransactionResult:
        """Sync allocatedAssets to match smart account balance (PnL update)"""

    def transmit_deallocated_assets(self, deallocated: Decimal, remaining: Decimal) -> TransactionResult:
        """Pull deallocated assets from operator wallet to fulfill withdrawals"""

    def allocate_assets(self, assets: Decimal) -> TransactionResult:
        """Deploy idle vault assets to the smart account"""

    # === READ FUNCTIONS ===
    def get_idle_assets(self) -> Decimal
    def get_pending_withdrawals(self) -> Decimal
    def get_allocated_assets(self) -> Decimal
```

### 4.2 SmartWrapperOperator Polling Logic

Location: `logarithm-acp-agent/acp_agents/smart_wrapper_operator.py`

The operator runs a continuous polling loop with these responsibilities:

1. **PnL Synchronization** (`_transmit_allocated_assets_if_needed`)
   - Compare `wrapper.allocatedAssets` vs `smart_account.balance`
   - If difference exists AND < 0.25% deviation → call `transmitAllocatedAssets()`
   - If deviation > 0.25% → alert via Telegram, require manual intervention

2. **Withdrawal Processing** (`_handle_pending_withdrawals`)
   - Detect `pendingWithdrawals() > 0`
   - Request withdrawal from Zyfai smart account
   - Once assets arrive → call `transmitDeallocatedAssets()`

3. **Idle Asset Deployment** (`_allocate_idle_assets`)
   - If `idleAssets() > 0` → call `allocateAssets()` to deploy to strategy

---

## 5. Security Model

### 5.1 Access Control

| Role | Capabilities |
|------|-------------|
| **User** | deposit, withdraw (up to idle), requestWithdraw, claim |
| **Smart Account** | transmitAllocatedAssets (with 0.25% deviation limit), transmitDeallocatedAssets |
| **Owner** | allocateAssets, setSmartAccount, forceTransmit* (no deviation limit), contract upgrades |

### 5.2 Deviation Protection

```solidity
uint256 constant MAX_DEVIATION_RATE = 0.0025 ether; // 0.25%

function _checkMaxDeviationRate(uint256 assets) internal view {
    uint256 deviationAbs = abs(assets - allocatedAssets());
    uint256 deviationRate = deviationAbs * 1e18 / allocatedAssets();
    if (deviationRate > MAX_DEVIATION_RATE) revert SA__ExceededMaxDeviationRate();
}
```

This prevents the operator from arbitrarily manipulating `allocatedAssets` to extract value.

### 5.3 Reentrancy Protection

- `claim()` marks `isClaimed = true` BEFORE transferring assets
- Uses OpenZeppelin's SafeERC20 for all transfers

---

## 6. Key Invariants

1. **Mutual Exclusivity**: `idleAssets() > 0` XOR `pendingWithdrawals() > 0` (never both positive)
2. **Accounting Identity**: `totalAssets() = vaultBalance + allocatedAssets + pending - obligations`
3. **FIFO Claims**: `isClaimable(key)` becomes true when `cumulativeClaimed + balance >= request.cumulative`

---

## 7. Validation Commands

```bash
# Build contracts
cd semi-async-vault && forge build

# Run tests
forge test -vvv

# Check specific test
forge test --match-test test_RequestWithdrawPartialIdleAssets -vvvv
```

---

## 8. Related Files

### Semi-Async-Vault (Solidity)
- `src/SemiAsyncRedeemVault.sol` - Abstract base with async withdrawal logic
- `src/ISemiAsyncRedeemVault.sol` - Interface definition
- `src/SmartAccountWrapper.sol` - Concrete implementation with operator controls
- `src/SmartAccountProxy.sol` - Beacon proxy for upgradeability

### Logarithm-ACP-Agent (Python)
- `contracts/smart_wrapper.py` - Python contract interface
- `contracts/abis/smart_wrapper.py` - Contract ABI
- `contracts/base.py` - Base Web3 contract class
- `acp_agents/smart_wrapper_operator.py` - Polling operator service
- `utils/smart_accounts/zyfai.py` - Zyfai smart account integration
