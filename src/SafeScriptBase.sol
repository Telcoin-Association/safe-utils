// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Safe} from "./Safe.sol";

/**
 * @title SafeScriptBase
 * @notice Base contract for Foundry scripts that interact with Gnosis Safe
 * @dev Provides automatic simulation vs broadcast detection
 *
 * USAGE:
 * ======
 *
 * SIMULATION MODE (no --broadcast flag):
 *   forge script script/MyScript.s.sol --rpc-url $RPC_URL --ffi -vvvv
 *
 *   - Executes transactions on a local fork
 *   - No Trezor/Ledger signing required
 *   - Shows what WOULD happen (deployments, state changes, reverts)
 *   - Safe state is simulated via storage manipulation
 *
 * BROADCAST MODE (with --broadcast flag):
 *   forge script script/MyScript.s.sol --rpc-url $RPC_URL --broadcast --ffi -vvvv
 *
 *   - Signs with Trezor/Ledger
 *   - Proposes transactions to Safe Transaction Service API
 *   - Requires manual execution in Safe UI
 *
 * ENVIRONMENT VARIABLES:
 * ======================
 *   DEPLOYER_SAFE_ADDRESS - The Gnosis Safe address
 *   SIGNER_ADDRESS        - The signer's address (owner on the Safe)
 *   DERIVATION_PATH       - HW wallet derivation path (e.g., "m/44'/60'/0'/0/0")
 *   HARDWARE_WALLET       - "trezor" or "ledger" (default: "ledger")
 */
abstract contract SafeScriptBase is Script {
    using Safe for *;

    // ============================================================
    //                         STATE
    // ============================================================

    /// @notice The Safe client instance
    Safe.Client internal safe;

    /// @notice The deployer Safe address
    address internal deployerSafeAddress;

    /// @notice The signer address (Safe owner)
    address internal signer;

    /// @notice The derivation path for HW wallet
    string internal derivationPath;

    /// @notice Track nonce for multiple transactions in same script run
    uint256 internal currentNonce;

    /// @notice Track if we're in simulation mode
    bool internal _isSimulation;

    // ============================================================
    //                      MODIFIERS
    // ============================================================

    /// @notice Ensures we're in simulation mode
    modifier onlySimulation() {
        require(_isSimulation, "This function only works in simulation mode");
        _;
    }

    /// @notice Ensures we're in broadcast mode
    modifier onlyBroadcast() {
        require(!_isSimulation, "This function only works in broadcast mode");
        _;
    }

    // ============================================================
    //                     SETUP FUNCTIONS
    // ============================================================

    /// @notice Initialize the Safe client and detect mode
    /// @dev Call this in your setUp() function
    function _initializeSafe() internal {
        deployerSafeAddress = vm.envAddress("DEPLOYER_SAFE_ADDRESS");
        safe.initialize(deployerSafeAddress);

        signer = vm.envAddress("SIGNER_ADDRESS");
        derivationPath = vm.envOr("DERIVATION_PATH", string(""));

        _isSimulation = Safe.isSimulationMode();

        _logMode();
    }

    /// @notice Log the current mode
    function _logMode() internal view {
        console.log("\n========================================");
        if (_isSimulation) {
            console.log("       SIMULATION MODE");
            console.log("  (no --broadcast flag detected)");
            console.log("");
            console.log("  Transactions will execute on fork");
            console.log("  No HW wallet signing required");
        } else {
            console.log("        BROADCAST MODE");
            console.log("   (--broadcast flag detected)");
            console.log("");
            console.log("  Transactions will be proposed to Safe API");
            console.log("  HW wallet signing required");
        }
        console.log("========================================\n");

        console.log("Safe Address:", deployerSafeAddress);
        console.log("Signer Address:", signer);
        if (!_isSimulation && bytes(derivationPath).length > 0) {
            console.log("Derivation Path:", derivationPath);
        }
    }

    // ============================================================
    //                  TRANSACTION HELPERS
    // ============================================================

    /// @notice Propose or simulate a single transaction
    /// @dev Automatically chooses based on broadcast mode
    /// @param target The target contract address
    /// @param data The calldata to send
    /// @param description Human-readable description for logging
    function _proposeTransaction(
        address target,
        bytes memory data,
        string memory description
    ) internal returns (bytes32) {
        console.log("\n---", description, "---");
        console.log("  Target:", target);

        bytes32 result;

        if (_isSimulation) {
            // Simulation mode: execute directly on fork
            bool success = safe.simulateTransactionNoSign(target, data, signer);

            if (!success) {
                console.log("  [SIMULATION FAILED] Transaction would revert!");
                console.log("");
                console.log("  DEBUGGING TIPS:");
                console.log(
                    "  1. Run with SAFE_DEBUG=true to bypass Safe and see inner revert"
                );
                console.log("  2. Check -vvvvv output for full stack trace");
                console.log(
                    "  3. Verify the target contract exists and has the expected code"
                );
                revert("Simulation failed - see logs above for details");
            }

            console.log("  [SIMULATION SUCCESS]");
            result = bytes32(uint256(1));

            // Increment nonce for next transaction
            // Note: In simulation, the Safe's nonce increases after execTransaction
            currentNonce++;
        } else {
            // Broadcast mode: propose to Safe API
            result = safe.proposeTransaction(
                target,
                data,
                signer,
                derivationPath
            );

            console.log("  [PROPOSED] SafeTxHash:", vm.toString(result));
            currentNonce++;
        }

        return result;
    }

    /// @notice Propose or simulate a transaction with expected deployment verification
    /// @dev Use this for CREATE2/CREATE3 deployments to verify the deployment succeeded
    /// @param target The target contract address (e.g., CreateX)
    /// @param data The calldata to send
    /// @param expectedDeployment The address where we expect code to be deployed
    /// @param description Human-readable description for logging
    function _proposeTransactionWithVerification(
        address target,
        bytes memory data,
        address expectedDeployment,
        string memory description
    ) internal returns (bytes32) {
        console.log("  Expected deployment at:", expectedDeployment);

        // Check if already deployed
        if (expectedDeployment.code.length > 0) {
            console.log(
                "  [SKIP] Already deployed with",
                expectedDeployment.code.length,
                "bytes of code"
            );
            return bytes32(uint256(2)); // Return 2 to indicate "already deployed"
        }

        bytes32 result = _proposeTransaction(target, data, description);

        // In simulation mode, verify the deployment actually happened
        if (_isSimulation && result == bytes32(uint256(1))) {
            if (expectedDeployment.code.length == 0) {
                console.log("");
                console.log("  [WARNING] Deployment verification failed!");
                console.log("  Expected code at:", expectedDeployment);
                console.log("  But address has no code after simulation.");
                console.log("");
                console.log("  This could mean:");
                console.log("  - The CREATE2/CREATE3 call reverted internally");
                console.log("  - The salt computation is wrong");
                console.log("  - The bytecode hash doesn't match expectations");
                revert(
                    "Deployment verification failed - no code at expected address"
                );
            } else {
                console.log(
                    "  [VERIFIED] Code deployed:",
                    expectedDeployment.code.length,
                    "bytes"
                );
            }
        }

        return result;
    }

    /// @notice Propose or simulate multiple transactions as a batch
    /// @dev Uses MultiSend for atomic execution
    /// @param targets Array of target addresses
    /// @param datas Array of calldatas
    /// @param description Human-readable description for logging
    function _proposeTransactions(
        address[] memory targets,
        bytes[] memory datas,
        string memory description
    ) internal returns (bytes32) {
        console.log("\n---", description, "---");
        console.log("  Batch size:", targets.length);

        bytes32 result;

        if (_isSimulation) {
            bool success = safe.simulateTransactionsNoSign(
                targets,
                datas,
                signer
            );

            if (!success) {
                console.log("  [SIMULATION FAILED] Batch would revert!");
                revert("Batch simulation failed");
            }

            console.log("  [SIMULATION SUCCESS]");
            result = bytes32(uint256(1));
            currentNonce++;
        } else {
            result = safe.proposeTransactions(
                targets,
                datas,
                signer,
                derivationPath
            );

            console.log("  [PROPOSED] SafeTxHash:", vm.toString(result));
            currentNonce++;
        }

        return result;
    }

    // ============================================================
    //                    UTILITY FUNCTIONS
    // ============================================================

    /// @notice Check if running in simulation mode
    function isSimulation() internal view returns (bool) {
        return _isSimulation;
    }

    /// @notice Get current Safe nonce (useful for address computation)
    function getSafeNonce() internal view returns (uint256) {
        return safe.getNonce();
    }

    /// @notice Get the Safe address
    function getSafeAddress() internal view returns (address) {
        return deployerSafeAddress;
    }
}
