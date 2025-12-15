# Safe-Utils Simulation Support Migration Guide

## Overview

This update adds **simulation mode** to safe-utils, allowing you to test Safe deployments on a local fork without:
- Hardware wallet (Trezor/Ledger) signing
- Proposing to the Safe Transaction Service API
- Any on-chain state changes

## Quick Start

### Simulation Mode (No `--broadcast` flag)
```bash
DEPLOYER_SAFE_ADDRESS=0x... \
SIGNER_ADDRESS=0x... \
forge script script/MyScript.s.sol \
  --rpc-url $RPC_URL \
  --ffi \
  -vvvv
```

### Broadcast Mode (With `--broadcast` flag)
```bash
DEPLOYER_SAFE_ADDRESS=0x... \
SIGNER_ADDRESS=0x... \
DERIVATION_PATH="m/44'/60'/0'/0/0" \
HARDWARE_WALLET=trezor \
forge script script/MyScript.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --ffi \
  -vvvv
```

## Multi-Sig Simulation

For Safes with threshold > 1, you can simulate with multiple signers:

### Multi-Sig Simulation Mode
```bash
DEPLOYER_SAFE_ADDRESS=0x... \
SIGNER_ADDRESS_0=0xAlice... \
SIGNER_ADDRESS_1=0xBob... \
SIGNER_ADDRESS_2=0xCharlie... \
forge script script/MyScript.s.sol \
  --rpc-url $RPC_URL \
  --ffi \
  -vvvv
```

### How Multi-Sig Simulation Works
1. Provide `threshold` or more signer addresses via indexed env vars
2. The simulation approves the tx hash in Safe storage for ALL signers
3. Signatures are sorted by address (as required by Safe)
4. The concatenated multi-sig signature is constructed automatically

### Multi-Sig Broadcast Mode
```bash
DEPLOYER_SAFE_ADDRESS=0x... \
SIGNER_ADDRESS_0=0xAlice... \
SIGNER_ADDRESS_1=0xBob... \
DERIVATION_PATH="m/44'/60'/0'/0/0" \
HARDWARE_WALLET=trezor \
forge script script/MyScript.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --ffi \
  -vvvv
```

In broadcast mode, only the primary signer (index 0) signs and proposes. Other signatures are collected via the Safe UI.

### Script Setup for Multi-Sig

Use `_initializeSafeMultiSig()` instead of `_initializeSafe()`:

```solidity
function setUp() public {
    _initializeSafeMultiSig();  // Loads SIGNER_ADDRESS_0, SIGNER_ADDRESS_1, etc.
}

## How It Works

### Simulation Mode
When `--broadcast` is NOT passed:
1. Detects simulation mode via `vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)`
2. Uses `vm.store()` to mark the transaction hash as "approved" in the Safe's storage
3. Calls `execTransaction` directly on the Safe (on the fork)
4. Shows success/failure and any state changes

### Broadcast Mode  
When `--broadcast` IS passed:
1. Detects broadcast mode
2. Signs via Trezor/Ledger FFI (as before)
3. Proposes to Safe Transaction Service API (as before)

## Migration Steps

### 1. Update Safe.sol

Replace your `Safe.sol` with the new version that includes:
- `isBroadcastMode()` / `isSimulationMode()` detection
- `simulateTransaction()` functions
- `simulateTransactionNoSign()` functions
- `executeOrPropose()` unified API

### 2. Option A: Use SafeScriptBase (Recommended)

Have your script base extend `SafeScriptBase`:

```solidity
// Before
abstract contract StablecoinScriptBase is Script {
    using Safe for *;
    Safe.Client internal safe;
    
    function setUp() public {
        safe.initialize(vm.envAddress("DEPLOYER_SAFE_ADDRESS"));
        // ...
    }
    
    function _proposeTransaction(address target, bytes memory data, string memory desc) internal {
        safe.proposeTransaction(target, data, signer, derivationPath);
    }
}

// After
import {SafeScriptBase} from "@safe-utils/SafeScriptBase.sol";

abstract contract StablecoinScriptBase is SafeScriptBase {
    // SafeScriptBase already has:
    // - Safe.Client internal safe;
    // - address internal deployerSafeAddress;
    // - address internal signer;
    // - string internal derivationPath;
    // - _proposeTransaction() with auto mode detection
    
    function setUp() public {
        _initializeSafe();  // Handles everything!
        // Your additional setup...
    }
}
```

### 3. Option B: Manual Integration

If you prefer to keep your existing structure:

```solidity
abstract contract StablecoinScriptBase is Script {
    using Safe for *;
    Safe.Client internal safe;
    bool internal _isSimulation;
    
    function setUp() public {
        safe.initialize(vm.envAddress("DEPLOYER_SAFE_ADDRESS"));
        _isSimulation = safe.isSimulationMode();
        // ...
    }
    
    function _proposeTransaction(
        address target, 
        bytes memory data, 
        string memory desc
    ) internal {
        if (_isSimulation) {
            // Simulation: execute on fork without HW wallet
            bool success = safe.simulateTransactionNoSign(target, data, signer);
            require(success, "Simulation failed");
        } else {
            // Broadcast: propose to Safe API with HW wallet
            safe.proposeTransaction(target, data, signer, derivationPath);
        }
    }
}
```

## New Functions Reference

### Mode Detection
```solidity
// Check if --broadcast flag was passed
bool broadcast = safe.isBroadcastMode();
bool simulation = safe.isSimulationMode();
```

### Simulation Functions
```solidity
// Simulate single transaction (requires HW wallet sig)
bool success = safe.simulateTransaction(self, to, data, sender, derivationPath);

// Simulate single transaction (NO HW wallet needed - uses storage manipulation)
bool success = safe.simulateTransactionNoSign(self, to, data, sender);

// Simulate batch (NO HW wallet needed)
bool success = safe.simulateTransactionsNoSign(self, targets, datas, sender);
```

### Multi-Sig Simulation Functions
```solidity
// Simulate single transaction with multiple signers
address[] memory signers = new address[](3);
signers[0] = 0xAlice;
signers[1] = 0xBob;
signers[2] = 0xCharlie;
bool success = safe.simulateTransactionMultiSigNoSign(self, to, data, signers);

// Simulate batch with multiple signers
bool success = safe.simulateTransactionsMultiSigNoSign(self, targets, datas, signers);
```

### Unified Execute/Propose
```solidity
// Automatically chooses simulation or propose based on mode
bytes32 result = safe.executeOrPropose(self, to, data, sender, derivationPath);
bytes32 result = safe.executeOrProposeMulti(self, targets, datas, sender, derivationPath);
```

## Troubleshooting

### "Simulation failed" error
The transaction would revert on-chain. To debug:

1. **Enable debug mode** to bypass Safe and see the actual revert:
   ```bash
   SAFE_DEBUG=true forge script ... -vvvvv
   ```

2. **Check the full trace** with maximum verbosity:
   ```bash
   forge script ... -vvvvv
   ```
   The typed calls in simulation mode now produce full stack traces.

3. **Verify your targets exist**:
   - Is CreateX deployed on this chain?
   - Does the implementation contract exist before deploying a beacon/proxy pointing to it?

### Deployment verification failed
If you see "no code at expected address":
- The CREATE2/CREATE3 salt computation may be wrong
- The bytecode hash may not match expectations
- The inner deployment reverted (check trace with `SAFE_DEBUG=true`)

### Mode not detected correctly
Set fallback environment variable:
```bash
SAFE_BROADCAST=true forge script ...  # Force broadcast mode
SAFE_BROADCAST=false forge script ... # Force simulation mode
```

### Getting full stack traces
The simulation now uses **typed calls** instead of low-level `.call()`, which means Foundry's `-vvvvv` flag will show the complete call stack including:
- Safe's `execTransaction` 
- The target contract's function
- Any internal calls and reverts

Example output with `-vvvvv`:
```
├─ [123456] Safe::execTransaction(...)
│   ├─ [98765] CreateX::deployCreate3(...)
│   │   ├─ [54321] → new MyContract(...)
│   │   │   └─ ← [Revert] SomeError()
│   │   └─ ← [Revert] 
│   └─ ← false
```

### Debug mode (`SAFE_DEBUG=true`)
When enabled, simulation bypasses the Safe and calls the target directly:
- Shows the actual revert reason from the target (not wrapped by Safe)
- Useful when Safe's `execTransaction` returns `false` but doesn't tell you why
- Only works for `Call` operations (not `DelegateCall`/MultiSend)

### Nonce issues in simulation
In simulation mode, each `execTransaction` increments the Safe's nonce. If you're doing multiple transactions, the simulation handles this automatically.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Script                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              SafeScriptBase                          │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │              Safe.sol Library                │    │    │
│  │  │                                              │    │    │
│  │  │  ┌──────────────┐    ┌──────────────────┐   │    │    │
│  │  │  │  Simulation  │    │    Broadcast     │   │    │    │
│  │  │  │              │    │                  │   │    │    │
│  │  │  │ vm.store()   │    │ sign() via FFI   │   │    │    │
│  │  │  │ vm.prank()   │    │ HTTP POST to API │   │    │    │
│  │  │  │ execTx()     │    │                  │   │    │    │
│  │  │  └──────────────┘    └──────────────────┘   │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```
