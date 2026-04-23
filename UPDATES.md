# Safe-Utils: Telcoin Additions Migration Guide

## Overview

This fork adds the following capabilities on top of `Recon-Fuzz/safe-utils`:

1. **Simulation mode** — execute a Safe transaction against a local fork without hardware-wallet signing or Safe Transaction Service API proposal
2. **Multi-sig simulation** — approve as N owners via storage manipulation to test threshold-based Safes
3. **Hardware wallet selection** — `HARDWARE_WALLET` env var with Trezor support (Ledger remains default)
4. **Deployment verification helper** — check CREATE2/CREATE3 deploys actually landed, with skip-if-already-deployed logic
5. **`SafeScriptBase`** — ready-to-extend base contract that auto-detects mode and handles nonce tracking
6. **Explicit-nonce signing/proposing** — new overloads that accept a custom nonce (breaking change on `proposeTransactionWithSignature`; additive elsewhere)

`--ffi` is required for every run (both simulation and broadcast) because signing and Safe API calls go through FFI.

---

## Breaking Changes

### `proposeTransactionWithSignature` now requires an explicit nonce

**Before** (upstream):
```solidity
function proposeTransactionWithSignature(
    Client storage self,
    address to,
    bytes memory data,
    address sender,
    bytes memory signature
) internal returns (bytes32 txHash);
```

**After** (this fork):
```solidity
function proposeTransactionWithSignature(
    Client storage self,
    address to,
    bytes memory data,
    address sender,
    bytes memory signature,
    uint256 nonce
) internal returns (bytes32 txHash);
```

Callers must pass the nonce they signed against. The previous implicit `getNonce(self)` behavior was replaced because proposing multiple sequential transactions in a single script run requires incrementing the nonce manually to avoid collisions — the Safe's on-chain nonce has not yet advanced when proposing (it only advances on execution).

To keep the old behavior, pass `safe.getNonce()`:
```solidity
safe.proposeTransactionWithSignature(to, data, sender, signature, safe.getNonce());
```

The batch variant `proposeTransactionsWithSignature` is *additive* — both the no-nonce (4-arg signature payload) and with-nonce (5-arg signature payload) overloads exist.

---

## Quick Start

### Simulation Mode (no `--broadcast`)
```bash
DEPLOYER_SAFE_ADDRESS=0x... \
SIGNER_ADDRESS=0x... \
forge script script/MyScript.s.sol \
  --rpc-url $RPC_URL \
  --ffi \
  -vvvv
```

### Broadcast Mode (with `--broadcast`)
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

Mode is auto-detected via `vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)`. You can override with `SAFE_BROADCAST=true|false` (see [Environment Variables](#environment-variables)).

---

## Simulation Mode

When `--broadcast` is NOT passed:
1. `isSimulationMode()` returns true.
2. The tx hash is marked "approved" in the Safe's storage via `vm.store()` (writing to slot-8 `approvedHashes[owner][hash] = 1`).
3. A synthetic "approved hash" signature (`r = owner, s = 0, v = 1`) is constructed.
4. `execTransaction` is called **as the signer** (via `vm.prank`) against the Safe on the fork.
5. Success/failure and resulting state changes are printed. On failure the call reverts with a decoded reason.

This means simulation works on Safes you don't control — you don't need any private key, just the owner addresses.

---

## Multi-Sig Simulation

For Safes with threshold > 1, provide `threshold` or more signer addresses via indexed env vars.

### Simulation
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

### How it works
1. Each signer's slot-8 `approvedHashes` entry is set to 1.
2. Signer addresses are sorted ascending (Safe requires sorted signatures).
3. A 65-byte "approved hash" signature is built per signer and concatenated.
4. `execTransaction` is called with the concatenated signatures.

### Broadcast Mode with Multi-Sig
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

In broadcast mode, **only the primary signer (index 0) signs and proposes.** Remaining signatures are collected via the Safe UI by other owners.

### Script Setup
Use `_initializeSafeMultiSig()` instead of `_initializeSafe()`:
```solidity
function setUp() public {
    _initializeSafeMultiSig();  // Loads SIGNER_ADDRESS_0, SIGNER_ADDRESS_1, ...
}
```
Falls back to `SIGNER_ADDRESS` if no indexed signers are present, so the same base works for single-signer scripts.

---

## Hardware Wallet Support

### `HARDWARE_WALLET` env var

| Value | Behavior |
|---|---|
| (unset) | Defaults to `ledger` |
| `ledger` | `cast wallet sign --ledger --data <EIP-712 typed data>` |
| `trezor` | `cast wallet sign --trezor <safeTxHash>` — raw hash, because `cast` does not support EIP-712 `--data` for Trezor |

### Trezor-specific signature adjustment

Trezor uses `eth_sign` (which prepends `"\x19Ethereum Signed Message:\n32"` to the hash) rather than signing the raw hash directly. The Safe contract distinguishes this by checking the signature's `v` value: if `v >= 31`, it treats the message as `eth_sign`-prefixed. The library adds `4` to `v` after Trezor returns the signature so the Safe accepts it:

```solidity
bytes memory output = vm.ffi(inputs);
uint8 v = uint8(output[64]);
output[64] = bytes1(v + 4);
return output;
```

Ledger signs the EIP-712 typed data natively, so no adjustment is needed.

### Signing without a hardware wallet
Pass an empty `derivationPath` (or leave the env var unset). The library falls back to `vm.sign(sender, safeTxHash)`, useful for testing with known private keys loaded via `vm.rememberKey`.

---

## Deployment Verification Helper

`SafeScriptBase` exposes `_proposeTransactionWithVerification()` for CREATE2/CREATE3 deployment scripts. It:

1. **Skips** the transaction if `expectedDeployment.code.length > 0` (already deployed → idempotent).
2. Runs the simulation/broadcast via the normal `_proposeTransaction()` path.
3. In simulation, **verifies** code exists at `expectedDeployment` after execution. If not, reverts with a diagnostic about possible causes (reverted internally, wrong salt, wrong bytecode hash).

```solidity
bytes32 result = _proposeTransactionWithVerification(
    createXAddress,     // target (e.g. CreateX factory)
    createCalldata,     // CREATE3 calldata
    expectedAddress,    // where we expect the contract to exist after
    "Deploy MyToken"    // description for logs
);
```

Return values:
- `bytes32(uint256(1))` — simulation/broadcast succeeded
- `bytes32(uint256(2))` — skipped (already deployed)
- reverts on failure

---

## Integration

### Option A: extend `SafeScriptBase` (recommended)
```solidity
import {SafeScriptBase} from "safe-utils/SafeScriptBase.sol";

abstract contract MyScriptBase is SafeScriptBase {
    function setUp() public {
        _initializeSafe();       // or _initializeSafeMultiSig()
        // ...your setup...
    }

    function run() public {
        _proposeTransaction(target, data, "Upgrade proxy");
        _proposeTransaction(anotherTarget, moreData, "Set param");
        // currentNonce auto-increments between calls
    }
}
```

`SafeScriptBase` gives you: `safe`, `deployerSafeAddress`, `signer`, `signers[]`, `derivationPath`, `currentNonce`, `_isSimulation`, and `onlySimulation` / `onlyBroadcast` modifiers.

### Option B: manual integration
```solidity
abstract contract MyScriptBase is Script {
    using Safe for *;
    Safe.Client internal safe;

    function setUp() public {
        safe.initialize(vm.envAddress("DEPLOYER_SAFE_ADDRESS"));
    }

    function _proposeTransaction(address target, bytes memory data) internal {
        if (Safe.isSimulationMode()) {
            require(safe.simulateTransactionNoSign(target, data, signer), "sim failed");
        } else {
            safe.proposeTransaction(target, data, signer, derivationPath);
        }
    }
}
```

---

## API Reference

All functions are in the `Safe` library and invoked via `using Safe for *;` unless noted. The `Client storage self` receiver is auto-passed and omitted from call-sites below.

### Mode Detection
```solidity
bool Safe.isBroadcastMode();
bool Safe.isSimulationMode();
```
Both read `vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)` with `SAFE_BROADCAST` as an env override. `isSimulationMode()` is simply `!isBroadcastMode()`.

### Simulation — single transaction
```solidity
// With hardware-wallet signing
bool success = safe.simulateTransaction(to, data, sender, derivationPath);

// No signing — approves via storage manipulation
bool success = safe.simulateTransactionNoSign(to, data, sender);
bool success = safe.simulateTransactionNoSign(to, data, operation, sender);

// Low-level entry with pre-built params
bool success = safe.simulateTransaction(execTransactionParams);
```

### Simulation — batched transactions (MultiSend, DelegateCall)
```solidity
bool success = safe.simulateTransactions(targets, datas, sender, derivationPath);
bool success = safe.simulateTransactionsNoSign(targets, datas, sender);
```

### Simulation — multi-sig
```solidity
// With hardware-wallet signing (signers must each have a signature; primary signs via FFI)
bool success = safe.simulateTransactionMultiSig(to, data, operation, signers);

// No signing — all signers marked "approved hash" in storage
bool success = safe.simulateTransactionMultiSigNoSign(to, data, signers);
bool success = safe.simulateTransactionsMultiSigNoSign(targets, datas, signers);
```

### Unified execute-or-propose (auto-detects mode)
```solidity
// Simulation → execute on fork with approved-hash. Broadcast → propose to Safe API.
bytes32 result = safe.executeOrPropose(to, data, sender, derivationPath);
bytes32 result = safe.executeOrProposeMulti(targets, datas, sender, derivationPath);
```
Returns the `safeTxHash` in broadcast mode, or `bytes32(uint256(1))` (success) / `bytes32(0)` (failure) in simulation.

### Propose (broadcast)
```solidity
// Sign + propose in one call
bytes32 hash = safe.proposeTransaction(to, data, sender);                    // no HW wallet (vm.sign)
bytes32 hash = safe.proposeTransaction(to, data, sender, derivationPath);    // HW wallet

// Propose with pre-computed signature and explicit nonce (breaking change — see above)
bytes32 hash = safe.proposeTransactionWithSignature(to, data, sender, signature, nonce);

// Batch variants
bytes32 hash = safe.proposeTransactions(targets, datas, sender, derivationPath);
bytes32 hash = safe.proposeTransactionsWithSignature(targets, datas, sender, signature);          // upstream-compatible
bytes32 hash = safe.proposeTransactionsWithSignature(targets, datas, sender, signature, nonce);   // new overload
```

### Signing
```solidity
bytes memory sig = safe.sign(to, data, operation, sender, derivationPath);              // uses current nonce
bytes memory sig = safe.sign(to, data, operation, sender, nonce, derivationPath);       // custom nonce
```

### Custom Errors
```solidity
error SimulationFailed(string reason);
error ExecTransactionFailed(bytes returnData);
// Plus existing upstream errors:
error ApiKitUrlNotFound(uint256 chainId);
error MultiSendCallOnlyNotFound(uint256 chainId);
error ArrayLengthsMismatch(uint256 a, uint256 b);
error ProposeTransactionFailed(uint256 statusCode, string response);
```

---

## `SafeScriptBase` Reference

### State
| Variable | Purpose |
|---|---|
| `Safe.Client internal safe` | The Safe client instance |
| `address internal deployerSafeAddress` | The Safe address from `DEPLOYER_SAFE_ADDRESS` |
| `address internal signer` | Primary signer (first, or `SIGNER_ADDRESS`) |
| `address[] internal signers` | All configured signers (multi-sig) |
| `string internal derivationPath` | HW wallet path (empty in simulation) |
| `uint256 internal currentNonce` | Auto-incrementing nonce across calls in one script run |
| `bool internal _isSimulation` | Cached simulation-mode flag |

### Setup
```solidity
_initializeSafe();           // single signer
_initializeSafeMultiSig();   // multi-sig (falls back to single if no indexed signers)
```

### Transaction helpers
```solidity
bytes32 _proposeTransaction(target, data, description);
bytes32 _proposeTransactionWithVerification(target, data, expectedDeployment, description);
bytes32 _proposeTransactions(targets, datas, description);
```

### Modifiers
```solidity
modifier onlySimulation();  // reverts if running in broadcast
modifier onlyBroadcast();   // reverts if running in simulation
```

### Utility getters
```solidity
bool    isSimulation();
uint256 getSafeNonce();
address getSafeAddress();
address[] getSigners();
uint256 getSignerCount();
bool    isMultiSig();
```

---

## Environment Variables

### Safe configuration
| Variable | Required | Default | Description |
|---|---|---|---|
| `DEPLOYER_SAFE_ADDRESS` | yes | — | The Gnosis Safe address |
| `SIGNER_ADDRESS` | single-signer | — | Signer address (owner on the Safe) |
| `SIGNER_ADDRESS_0`, `SIGNER_ADDRESS_1`, ... | multi-sig | — | Indexed signer addresses. Used by `_initializeSafeMultiSig()` |
| `DERIVATION_PATH` | broadcast only | `""` | HW wallet derivation path, e.g. `m/44'/60'/0'/0/0` |
| `HARDWARE_WALLET` | no | `ledger` | `ledger` or `trezor` |

### Mode / debugging
| Variable | Default | Description |
|---|---|---|
| `SAFE_BROADCAST` | auto-detected | Force broadcast mode (`true`) or simulation mode (`false`), overriding the Forge context detection |
| `SAFE_DEBUG` | `false` | In simulation, bypass the Safe and call the target contract directly. Reveals the inner revert reason. Only works for `Call` operations (not `DelegateCall`/MultiSend) |

---

## Debug Mode (`SAFE_DEBUG=true`)

When enabled and running in simulation, the library skips `Safe.execTransaction` and calls the target contract directly via `vm.prank(sender)`. This is useful when `execTransaction` returns `false` without telling you why — calling the target directly surfaces the native revert reason.

Caveats:
- Only works for `Call` operation. Batched/MultiSend transactions (`DelegateCall`) are not supported in debug mode because they rely on being executed through the Safe.
- Any Safe-specific checks (nonce, threshold, signature validity, refund logic) are bypassed — don't use this to validate Safe behavior, only to debug the target call.

---

## Troubleshooting

### "Simulation failed" error
The transaction would revert on-chain. To debug:

1. Enable debug mode to bypass Safe and see the native revert:
   ```bash
   SAFE_DEBUG=true forge script ... --ffi -vvvvv
   ```
2. Maximize verbosity for full stack traces (simulation uses typed calls, so traces include the Safe → target chain):
   ```bash
   forge script ... --ffi -vvvvv
   ```
3. Verify the target contract exists on the forked chain.

### Deployment verification failed
If `_proposeTransactionWithVerification` reverts with "no code at expected address":
- The CREATE2/CREATE3 salt computation is wrong
- The bytecode hash doesn't match expectations
- The inner deployment reverted (use `SAFE_DEBUG=true` to see why)

### Mode not detected correctly
```bash
SAFE_BROADCAST=true forge script ...   # force broadcast
SAFE_BROADCAST=false forge script ...  # force simulation
```

### Getting full stack traces
Simulation uses typed calls (`ISafeSmartAccount(safe).execTransaction(...)` via `try/catch`) instead of low-level `.call()`, so Foundry's `-vvvvv` shows the full stack:
```
├─ [123456] Safe::execTransaction(...)
│   ├─ [98765] CreateX::deployCreate3(...)
│   │   ├─ [54321] → new MyContract(...)
│   │   │   └─ ← [Revert] SomeError()
│   │   └─ ← [Revert]
│   └─ ← false
```

### Nonce conflicts when proposing multiple transactions
When proposing multiple transactions in one script run, the Safe's on-chain nonce hasn't advanced yet (it only advances on execution). `SafeScriptBase` tracks `currentNonce` and increments it per propose call. If integrating manually, pass an explicit incrementing nonce into `sign()` and `proposeTransactionWithSignature()`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Script                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              SafeScriptBase                         │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │              Safe.sol Library               │    │    │
│  │  │                                             │    │    │
│  │  │  ┌──────────────┐    ┌──────────────────┐   │    │    │
│  │  │  │  Simulation  │    │    Broadcast     │   │    │    │
│  │  │  │              │    │                  │   │    │    │
│  │  │  │ vm.store()   │    │ cast wallet sign │   │    │    │
│  │  │  │ vm.prank()   │    │  (via FFI)       │   │    │    │
│  │  │  │ execTx()     │    │ HTTP POST to API │   │    │    │
│  │  │  └──────────────┘    └──────────────────┘   │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```
