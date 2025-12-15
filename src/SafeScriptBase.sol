// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Safe} from "./Safe.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";

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
 * ENVIRONMENT VARIABLES (Single Signer):
 * ======================================
 *   DEPLOYER_SAFE_ADDRESS - The Gnosis Safe address
 *   SIGNER_ADDRESS        - The signer's address (owner on the Safe)
 *   DERIVATION_PATH       - HW wallet derivation path (e.g., "m/44'/60'/0'/0/0")
 *   HARDWARE_WALLET       - "trezor" or "ledger" (default: "ledger")
 *
 * ENVIRONMENT VARIABLES (Multi-Sig Simulation):
 * =============================================
 *   DEPLOYER_SAFE_ADDRESS - The Gnosis Safe address
 *   SIGNER_ADDRESS_0      - First signer address
 *   SIGNER_ADDRESS_1      - Second signer address
 *   SIGNER_ADDRESS_2      - Third signer address (and so on...)
 *   DERIVATION_PATH       - HW wallet derivation path for primary signer (broadcast mode)
 *   HARDWARE_WALLET       - "trezor" or "ledger" (default: "ledger")
 *
 * Note: For multi-sig, provide at least `threshold` number of signers.
 *       In broadcast mode, only the primary signer (index 0) signs and proposes.
 *       Other signatures are collected via the Safe UI.
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

    /// @notice The signer address (Safe owner) - primary signer for broadcast
    address internal signer;

    /// @notice Array of signers for multi-sig simulation
    address[] internal signers;

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

    /// @notice Initialize Safe client with multiple signers for multi-sig Safes
    /// @dev Set SIGNER_ADDRESS_0, SIGNER_ADDRESS_1, etc. in environment
    ///      Falls back to SIGNER_ADDRESS if no indexed signers found
    function _initializeSafeMultiSig() internal {
        deployerSafeAddress = vm.envAddress("DEPLOYER_SAFE_ADDRESS");
        safe.initialize(deployerSafeAddress);

        // Load signers from indexed env vars: SIGNER_ADDRESS_0, SIGNER_ADDRESS_1, ...
        uint256 i = 0;
        while (true) {
            string memory envKey = string.concat(
                "SIGNER_ADDRESS_",
                vm.toString(i)
            );
            address signerAddr = vm.envOr(envKey, address(0));
            if (signerAddr == address(0)) break;
            signers.push(signerAddr);
            i++;
        }

        // Fallback to single signer if no indexed signers found
        if (signers.length == 0) {
            signer = vm.envAddress("SIGNER_ADDRESS");
            signers.push(signer);
        } else {
            signer = signers[0]; // Primary signer for broadcast mode
        }

        derivationPath = vm.envOr("DERIVATION_PATH", string(""));
        _isSimulation = Safe.isSimulationMode();

        _logModeMultiSig();
    }

    /// @notice Log mode with multi-sig details
    function _logModeMultiSig() internal view {
        console.log("\n========================================");
        if (_isSimulation) {
            console.log("    SIMULATION MODE (Multi-Sig)");
            console.log("  (no --broadcast flag detected)");
            console.log("");
            console.log("  Transactions will execute on fork");
            console.log("  Simulating", signers.length, "signers");
        } else {
            console.log("        BROADCAST MODE");
            console.log("   (--broadcast flag detected)");
            console.log("");
            console.log("  Transactions will be proposed to Safe API");
            console.log("  Primary signer will sign with HW wallet");
        }
        console.log("========================================\n");

        console.log("Safe Address:", deployerSafeAddress);
        console.log("Signers:", signers.length);
        for (uint256 i = 0; i < signers.length; i++) {
            if (i == 0 && !_isSimulation) {
                console.log("  [PRIMARY]", i, ":", signers[i]);
            } else {
                console.log("          ", i, ":", signers[i]);
            }
        }
        if (!_isSimulation && bytes(derivationPath).length > 0) {
            console.log("Derivation Path:", derivationPath);
        }
    }

    // ============================================================
    //                  TRANSACTION HELPERS
    // ============================================================

    /// @notice Propose or simulate a single transaction
    /// @dev Automatically chooses based on broadcast mode
    ///      Uses multi-sig simulation if multiple signers are configured
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
            bool success;

            // Use multi-sig simulation if we have multiple signers
            if (signers.length > 1) {
                success = safe.simulateTransactionMultiSigNoSign(
                    target,
                    data,
                    signers
                );
            } else {
                success = safe.simulateTransactionNoSign(target, data, signer);
            }

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
            // Broadcast mode: propose to Safe API with explicit nonce
            bytes memory signature = safe.sign(
                target,
                data,
                Enum.Operation.Call,
                signer,
                currentNonce,
                derivationPath
            );

            result = safe.proposeTransactionWithSignature(
                target,
                data,
                signer,
                signature,
                currentNonce
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
    ///      Uses multi-sig simulation if multiple signers are configured
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
            bool success;

            // Use multi-sig simulation if we have multiple signers
            if (signers.length > 1) {
                success = safe.simulateTransactionsMultiSigNoSign(
                    targets,
                    datas,
                    signers
                );
            } else {
                success = safe.simulateTransactionsNoSign(
                    targets,
                    datas,
                    signer
                );
            }

            if (!success) {
                console.log("  [SIMULATION FAILED] Batch would revert!");
                revert("Batch simulation failed");
            }

            console.log("  [SIMULATION SUCCESS]");
            result = bytes32(uint256(1));
            currentNonce++;
        } else {
            // Broadcast mode: propose to Safe API with explicit nonce
            (address to, bytes memory data) = safe
                .getProposeTransactionsTargetAndData(targets, datas);

            bytes memory signature = safe.sign(
                to,
                data,
                Enum.Operation.DelegateCall,
                signer,
                currentNonce,
                derivationPath
            );

            result = safe.proposeTransactionsWithSignature(
                targets,
                datas,
                signer,
                signature,
                currentNonce
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

    /// @notice Get all configured signers
    function getSigners() internal view returns (address[] memory) {
        return signers;
    }

    /// @notice Get the number of signers
    function getSignerCount() internal view returns (uint256) {
        return signers.length;
    }

    /// @notice Check if running in multi-sig mode
    function isMultiSig() internal view returns (bool) {
        return signers.length > 1;
    }
}
