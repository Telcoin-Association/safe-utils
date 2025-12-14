// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {HTTP} from "solidity-http/HTTP.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";
import {ISafeSmartAccount} from "./ISafeSmartAccount.sol";
import {console} from "forge-std/console.sol";

library Safe {
    using HTTP for *;

    /// forge-lint: disable-next-line(screaming-snake-case-const)
    Vm constant vm =
        Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    // https://github.com/safe-global/safe-smart-account/blob/release/v1.4.1/contracts/SafeStorage.sol
    bytes32 constant SAFE_THRESHOLD_STORAGE_SLOT = bytes32(uint256(4));

    // https://github.com/safe-global/safe-deployments/blob/v1.37.32/src/assets/v1.3.0/multi_send_call_only.json
    address constant MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL =
        0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    address constant MULTI_SEND_CALL_ONLY_ADDRESS_EIP155 =
        0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B;
    address constant MULTI_SEND_CALL_ONLY_ADDRESS_ZKSYNC =
        0xf220D3b4DFb23C4ade8C88E526C1353AbAcbC38F;

    error ApiKitUrlNotFound(uint256 chainId);
    error MultiSendCallOnlyNotFound(uint256 chainId);
    error ArrayLengthsMismatch(uint256 a, uint256 b);
    error ProposeTransactionFailed(uint256 statusCode, string response);
    error SimulationFailed(string reason);
    error ExecTransactionFailed(bytes returnData);

    struct Instance {
        address safe;
        HTTP.Client http;
        mapping(uint256 chainId => string) urls;
        mapping(uint256 chainId => MultiSendCallOnly) multiSendCallOnly;
        string requestBody;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Client {
        Instance[] instances;
    }

    struct ExecTransactionParams {
        address to;
        uint256 value;
        bytes data;
        Enum.Operation operation;
        address sender;
        bytes signature;
        uint256 nonce;
    }

    // ============================================================
    //                     BROADCAST MODE DETECTION
    // ============================================================

    /// @notice Check if we're in broadcast mode (--broadcast flag passed)
    /// @dev Uses Foundry's context detection
    function isBroadcastMode() internal view returns (bool) {
        // Try to detect broadcast context
        // In Foundry, ScriptBroadcast context is set when --broadcast is passed
        try vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) returns (
            bool isBroadcast
        ) {
            return isBroadcast;
        } catch {
            // Fallback: check environment variable
            return vm.envOr("SAFE_BROADCAST", false);
        }
    }

    /// @notice Check if we're in simulation mode (no --broadcast flag)
    function isSimulationMode() internal view returns (bool) {
        return !isBroadcastMode();
    }

    // ============================================================
    //                      INITIALIZATION
    // ============================================================

    function initialize(
        Client storage self,
        address safe
    ) internal returns (Client storage) {
        self.instances.push();
        Instance storage i = self.instances[self.instances.length - 1];
        i.safe = safe;
        // https://github.com/safe-global/safe-core-sdk/blob/4d89cb9b1559e4349c323a48a10caf685f7f8c88/packages/api-kit/src/utils/config.ts
        i.urls[1] = "https://api.safe.global/tx-service/eth/api";
        i.urls[10] = "https://api.safe.global/tx-service/oeth/api";
        i.urls[56] = "https://api.safe.global/tx-service/bnb/api";
        i.urls[100] = "https://api.safe.global/tx-service/gno/api";
        i.urls[130] = "https://api.safe.global/tx-service/unichain/api";
        i.urls[137] = "https://api.safe.global/tx-service/pol/api";
        i.urls[196] = "https://api.safe.global/tx-service/okb/api";
        i.urls[324] = "https://api.safe.global/tx-service/zksync/api";
        i.urls[480] = "https://api.safe.global/tx-service/wc/api";
        i.urls[1101] = "https://api.safe.global/tx-service/zkevm/api";
        i.urls[5000] = "https://api.safe.global/tx-service/mantle/api";
        i.urls[8453] = "https://api.safe.global/tx-service/base/api";
        i.urls[42161] = "https://api.safe.global/tx-service/arb1/api";
        i.urls[42220] = "https://api.safe.global/tx-service/celo/api";
        i.urls[43114] = "https://api.safe.global/tx-service/avax/api";
        i.urls[59144] = "https://api.safe.global/tx-service/linea/api";
        i.urls[84532] = "https://api.safe.global/tx-service/basesep/api";
        i.urls[534352] = "https://api.safe.global/tx-service/scr/api";
        i.urls[11155111] = "https://api.safe.global/tx-service/sep/api";
        i.urls[1313161554] = "https://api.safe.global/tx-service/aurora/api";

        // https://github.com/safe-global/safe-deployments/blob/v1.37.32/src/assets/v1.3.0/multi_send_call_only.json
        i.multiSendCallOnly[1] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[10] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[56] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[100] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[130] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[137] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[196] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[324] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_ZKSYNC
        );
        i.multiSendCallOnly[480] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[1101] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[5000] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[8453] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[42161] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[42220] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[43114] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[59144] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[84532] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[534352] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[11155111] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );
        i.multiSendCallOnly[1313161554] = MultiSendCallOnly(
            MULTI_SEND_CALL_ONLY_ADDRESS_CANONICAL
        );

        i.http.initialize().withHeader("Content-Type", "application/json");
        return self;
    }

    function instance(
        Client storage self
    ) internal view returns (Instance storage) {
        return self.instances[self.instances.length - 1];
    }

    function getApiKitUrl(
        Client storage self,
        uint256 chainId
    ) internal view returns (string memory) {
        string memory url = instance(self).urls[chainId];
        if (bytes(url).length == 0) {
            revert ApiKitUrlNotFound(chainId);
        }
        return url;
    }

    function getMultiSendCallOnly(
        Client storage self,
        uint256 chainId
    ) internal view returns (MultiSendCallOnly) {
        MultiSendCallOnly multiSendCallOnly = instance(self).multiSendCallOnly[
            chainId
        ];
        if (address(multiSendCallOnly) == address(0)) {
            revert MultiSendCallOnlyNotFound(chainId);
        }
        return multiSendCallOnly;
    }

    function getNonce(Client storage self) internal view returns (uint256) {
        return ISafeSmartAccount(instance(self).safe).nonce();
    }

    function getSafeTxHash(
        Client storage self,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 nonce
    ) internal view returns (bytes32) {
        return
            ISafeSmartAccount(instance(self).safe).getTransactionHash(
                to,
                value,
                data,
                operation,
                0,
                0,
                0,
                address(0),
                address(0),
                nonce
            );
    }

    // ============================================================
    //                    SIMULATION FUNCTIONS
    // ============================================================

    /// @notice Decode revert reason from return data
    /// @param returnData The raw return data from a failed call
    /// @return reason Human-readable revert reason
    function _decodeRevertReason(
        bytes memory returnData
    ) internal pure returns (string memory reason) {
        // Check for standard Error(string) selector: 0x08c379a0
        if (returnData.length >= 68) {
            bytes4 selector;
            assembly {
                selector := mload(add(returnData, 32))
            }
            if (selector == 0x08c379a0) {
                // Decode Error(string)
                assembly {
                    returnData := add(returnData, 4)
                }
                return abi.decode(returnData, (string));
            }
        }

        // Check for Panic(uint256) selector: 0x4e487b71
        if (returnData.length >= 36) {
            bytes4 selector;
            assembly {
                selector := mload(add(returnData, 32))
            }
            if (selector == 0x4e487b71) {
                uint256 panicCode;
                assembly {
                    panicCode := mload(add(returnData, 36))
                }
                if (panicCode == 0x01) return "Panic: Assertion failed";
                if (panicCode == 0x11)
                    return "Panic: Arithmetic overflow/underflow";
                if (panicCode == 0x12) return "Panic: Division by zero";
                if (panicCode == 0x21) return "Panic: Invalid enum value";
                if (panicCode == 0x32) return "Panic: Array out of bounds";
                if (panicCode == 0x41) return "Panic: Out of memory";
                if (panicCode == 0x51)
                    return "Panic: Uninitialized function pointer";
                return string.concat("Panic: Code ", vm.toString(panicCode));
            }
        }

        // Return raw hex if we can't decode
        if (returnData.length > 0) {
            return string.concat("Raw revert data: ", vm.toString(returnData));
        }

        return "No revert reason provided";
    }

    /// @notice Simulate a Safe transaction on the current fork using typed calls for full trace support
    /// @dev Uses vm.prank to execute as a Safe owner. For single-signer Safes.
    /// @param self The Safe client
    /// @param params The transaction parameters
    /// @return success Whether the simulation succeeded
    function simulateTransaction(
        Client storage self,
        ExecTransactionParams memory params
    ) internal returns (bool success) {
        address safeAddress = instance(self).safe;

        console.log("\n[SIMULATION] Simulating Safe transaction...");
        console.log("  Safe:", safeAddress);
        console.log("  To:", params.to);
        console.log("  Value:", params.value);
        console.log("  Operation:", uint8(params.operation));
        console.log("  Nonce:", params.nonce);
        console.log("  Data length:", params.data.length);

        // Check if debug mode is enabled (bypass Safe, call target directly)
        bool debugMode = vm.envOr("SAFE_DEBUG", false);

        if (debugMode) {
            console.log(
                "\n[DEBUG MODE] Bypassing Safe, calling target directly..."
            );
            return _simulateDirectCall(self, params);
        }

        // Use typed call for proper Foundry trace support with -vvvvv
        // This allows Foundry to show the full call stack
        vm.prank(params.sender);
        try
            ISafeSmartAccount(safeAddress).execTransaction(
                params.to,
                params.value,
                params.data,
                params.operation,
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                payable(0), // refundReceiver
                params.signature
            )
        returns (bool execSuccess) {
            if (execSuccess) {
                console.log(
                    "[SIMULATION] SUCCESS - Transaction executed correctly"
                );
                return true;
            } else {
                // execTransaction returned false (inner call failed but didn't revert)
                console.log(
                    "[SIMULATION] FAILED - Safe.execTransaction returned false"
                );
                console.log(
                    "  This means the inner call reverted but Safe caught it"
                );
                console.log(
                    "  Run with SAFE_DEBUG=true to see the inner revert reason"
                );
                return false;
            }
        } catch Error(string memory reason) {
            console.log("[SIMULATION] FAILED - Reverted with reason:");
            console.log(" ", reason);
            return false;
        } catch Panic(uint256 code) {
            console.log("[SIMULATION] FAILED - Panic code:", code);
            return false;
        } catch (bytes memory returnData) {
            console.log("[SIMULATION] FAILED - Reverted with:");
            console.log(" ", _decodeRevertReason(returnData));
            return false;
        }
    }

    /// @notice Simulate by calling the target directly (bypassing Safe) for debugging
    /// @dev This shows the actual revert reason from the target contract
    function _simulateDirectCall(
        Client storage self,
        ExecTransactionParams memory params
    ) internal returns (bool success) {
        address safeAddress = instance(self).safe;

        console.log("[DEBUG] Pranking as Safe and calling target directly");
        console.log("  Target:", params.to);

        if (params.operation == Enum.Operation.Call) {
            // Regular call: prank as Safe and call target
            vm.prank(safeAddress);
            (success, ) = params.to.call{value: params.value}(params.data);
        } else {
            // DelegateCall: we can't easily simulate this directly
            // But we can at least try to decode what MultiSend would do
            console.log(
                "[DEBUG] DelegateCall detected - simulating via Safe anyway"
            );
            console.log(
                "  Note: For DelegateCall debugging, check the MultiSend transactions"
            );

            // Fall back to Safe execution for DelegateCall
            vm.prank(params.sender);
            try
                ISafeSmartAccount(safeAddress).execTransaction(
                    params.to,
                    params.value,
                    params.data,
                    params.operation,
                    0,
                    0,
                    0,
                    address(0),
                    payable(0),
                    params.signature
                )
            returns (bool execSuccess) {
                success = execSuccess;
            } catch {
                success = false;
            }
        }

        if (success) {
            console.log("[DEBUG] Direct call SUCCESS");

            // Verify deployment if this looks like a CREATE2/CREATE3 call
            _verifyDeploymentIfApplicable(params.to, params.data);
        } else {
            console.log("[DEBUG] Direct call FAILED");
            console.log("  Check the trace above for the actual revert reason");
        }

        return success;
    }

    /// @notice Check if a deployment actually produced code
    /// @dev Called after simulation to verify CREATE2/CREATE3 worked
    function _verifyDeploymentIfApplicable(
        address target,
        bytes memory data
    ) internal view {
        // Check if this is a CreateX call
        if (target != 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed) {
            return; // Not CreateX
        }

        // Try to identify the function being called
        if (data.length < 4) return;

        bytes4 selector;
        assembly {
            selector := mload(add(data, 32))
        }

        // deployCreate2: 0x26307668
        // deployCreate3: 0x7f565360
        // (selectors may vary - these are common ones)

        console.log("[DEBUG] CreateX call detected");
        console.log("  Selector:", vm.toString(bytes4(selector)));
        console.log(
            "  Tip: Check the trace to see the deployed address and verify it has code"
        );
    }

    /// @notice Simulate a single transaction
    /// @dev Convenience wrapper that builds params and simulates
    function simulateTransaction(
        Client storage self,
        address to,
        bytes memory data,
        address sender,
        string memory derivationPath
    ) internal returns (bool success) {
        uint256 nonce = getNonce(self);
        bytes memory signature = sign(
            self,
            to,
            data,
            Enum.Operation.Call,
            sender,
            nonce,
            derivationPath
        );

        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: sender,
            signature: signature,
            nonce: nonce
        });

        return simulateTransaction(self, params);
    }

    /// @notice Simulate multiple transactions via MultiSend
    function simulateTransactions(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender,
        string memory derivationPath
    ) internal returns (bool success) {
        (address to, bytes memory data) = getProposeTransactionsTargetAndData(
            self,
            targets,
            datas
        );

        uint256 nonce = getNonce(self);
        bytes memory signature = sign(
            self,
            to,
            data,
            Enum.Operation.DelegateCall,
            sender,
            nonce,
            derivationPath
        );

        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.DelegateCall,
            sender: sender,
            signature: signature,
            nonce: nonce
        });

        return simulateTransaction(self, params);
    }

    /// @notice Simulate without requiring hardware wallet signature
    /// @dev Creates an "approved hash" style signature for simulation only
    function simulateTransactionNoSign(
        Client storage self,
        address to,
        bytes memory data,
        address sender
    ) internal returns (bool success) {
        return
            simulateTransactionNoSign(
                self,
                to,
                data,
                Enum.Operation.Call,
                sender
            );
    }

    /// @notice Simulate without requiring hardware wallet signature (with operation type)
    /// @dev Creates an "approved hash" style signature for simulation only
    function simulateTransactionNoSign(
        Client storage self,
        address to,
        bytes memory data,
        Enum.Operation operation,
        address sender
    ) internal returns (bool success) {
        uint256 nonce = getNonce(self);
        address safeAddress = instance(self).safe;
        bytes32 txHash = getSafeTxHash(self, to, 0, data, operation, nonce);

        // Store the hash as approved (approvedHashes[owner][hash] = 1)
        // Slot: keccak256(abi.encode(hash, keccak256(abi.encode(owner, 8))))
        // Safe's approvedHashes is at slot 8
        bytes32 ownerSlot = keccak256(abi.encode(sender, uint256(8)));
        bytes32 approvalSlot = keccak256(abi.encode(txHash, ownerSlot));
        vm.store(safeAddress, approvalSlot, bytes32(uint256(1)));

        // Create approved hash signature (r=owner, s=0, v=1)
        bytes memory signature = abi.encodePacked(
            bytes32(uint256(uint160(sender))), // r = owner address padded
            bytes32(0), // s = 0
            uint8(1) // v = 1 means approved hash
        );

        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: operation,
            sender: sender,
            signature: signature,
            nonce: nonce
        });

        return simulateTransaction(self, params);
    }

    /// @notice Simulate multiple transactions without hardware wallet signature
    function simulateTransactionsNoSign(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender
    ) internal returns (bool success) {
        (address to, bytes memory data) = getProposeTransactionsTargetAndData(
            self,
            targets,
            datas
        );

        uint256 nonce = getNonce(self);
        address safeAddress = instance(self).safe;
        bytes32 txHash = getSafeTxHash(
            self,
            to,
            0,
            data,
            Enum.Operation.DelegateCall,
            nonce
        );

        // Store the hash as approved
        bytes32 ownerSlot = keccak256(abi.encode(sender, uint256(8)));
        bytes32 approvalSlot = keccak256(abi.encode(txHash, ownerSlot));
        vm.store(safeAddress, approvalSlot, bytes32(uint256(1)));

        // Create approved hash signature
        bytes memory signature = abi.encodePacked(
            bytes32(uint256(uint160(sender))),
            bytes32(0),
            uint8(1)
        );

        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.DelegateCall,
            sender: sender,
            signature: signature,
            nonce: nonce
        });

        return simulateTransaction(self, params);
    }

    // ============================================================
    //          UNIFIED EXECUTE/PROPOSE (AUTO-DETECTS MODE)
    // ============================================================

    /// @notice Execute or propose a transaction based on broadcast mode
    /// @dev In simulation mode: executes on fork. In broadcast mode: proposes to Safe API.
    /// @param self The Safe client
    /// @param to Target address
    /// @param data Calldata
    /// @param sender Signer address
    /// @param derivationPath HW wallet derivation path (empty for simulation)
    /// @return result In broadcast mode: safeTxHash. In simulation: success as bytes32.
    function executeOrPropose(
        Client storage self,
        address to,
        bytes memory data,
        address sender,
        string memory derivationPath
    ) internal returns (bytes32 result) {
        if (isBroadcastMode()) {
            console.log("\n[BROADCAST MODE] Proposing to Safe API...");
            return proposeTransaction(self, to, data, sender, derivationPath);
        } else {
            console.log("\n[SIMULATION MODE] Executing on fork...");
            bool success = simulateTransactionNoSign(self, to, data, sender);
            return success ? bytes32(uint256(1)) : bytes32(0);
        }
    }

    /// @notice Execute or propose multiple transactions based on broadcast mode
    function executeOrProposeMulti(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender,
        string memory derivationPath
    ) internal returns (bytes32 result) {
        if (isBroadcastMode()) {
            console.log("\n[BROADCAST MODE] Proposing batch to Safe API...");
            return
                proposeTransactions(
                    self,
                    targets,
                    datas,
                    sender,
                    derivationPath
                );
        } else {
            console.log("\n[SIMULATION MODE] Executing batch on fork...");
            bool success = simulateTransactionsNoSign(
                self,
                targets,
                datas,
                sender
            );
            return success ? bytes32(uint256(1)) : bytes32(0);
        }
    }

    // ============================================================
    //                    PROPOSE FUNCTIONS (ORIGINAL)
    // ============================================================

    // https://github.com/safe-global/safe-core-sdk/blob/r60/packages/api-kit/src/SafeApiKit.ts#L574
    function proposeTransaction(
        Client storage self,
        ExecTransactionParams memory params
    ) internal returns (bytes32) {
        bytes32 safeTxHash = getSafeTxHash(
            self,
            params.to,
            params.value,
            params.data,
            params.operation,
            params.nonce
        );
        instance(self).requestBody = vm.serializeAddress(
            ".proposeTransaction",
            "to",
            params.to
        );
        instance(self).requestBody = vm.serializeUint(
            ".proposeTransaction",
            "value",
            params.value
        );
        instance(self).requestBody = vm.serializeBytes(
            ".proposeTransaction",
            "data",
            params.data
        );
        instance(self).requestBody = vm.serializeUint(
            ".proposeTransaction",
            "operation",
            uint8(params.operation)
        );
        instance(self).requestBody = vm.serializeBytes32(
            ".proposeTransaction",
            "contractTransactionHash",
            safeTxHash
        );
        instance(self).requestBody = vm.serializeAddress(
            ".proposeTransaction",
            "sender",
            params.sender
        );
        instance(self).requestBody = vm.serializeBytes(
            ".proposeTransaction",
            "signature",
            params.signature
        );
        instance(self).requestBody = vm.serializeUint(
            ".proposeTransaction",
            "safeTxGas",
            0
        );
        instance(self).requestBody = vm.serializeUint(
            ".proposeTransaction",
            "baseGas",
            0
        );
        instance(self).requestBody = vm.serializeUint(
            ".proposeTransaction",
            "gasPrice",
            0
        );
        instance(self).requestBody = vm.serializeUint(
            ".proposeTransaction",
            "nonce",
            params.nonce
        );

        HTTP.Response memory response = instance(self)
            .http
            .instance()
            .POST(
                string.concat(
                    getApiKitUrl(self, block.chainid),
                    "/v1/safes/",
                    vm.toString(instance(self).safe),
                    "/multisig-transactions/"
                )
            )
            .withBody(instance(self).requestBody)
            .request();

        // The response status should be 2xx, otherwise there was an issue
        if (response.status < 200 || response.status >= 300) {
            revert ProposeTransactionFailed(response.status, response.data);
        }

        return safeTxHash;
    }

    function proposeTransaction(
        Client storage self,
        address to,
        bytes memory data,
        address sender
    ) internal returns (bytes32) {
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: sender,
            signature: sign(
                self,
                to,
                data,
                Enum.Operation.Call,
                sender,
                string("")
            ),
            nonce: getNonce(self)
        });
        return proposeTransaction(self, params);
    }

    function proposeTransaction(
        Client storage self,
        address to,
        bytes memory data,
        address sender,
        string memory derivationPath
    ) internal returns (bytes32) {
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: sender,
            signature: sign(
                self,
                to,
                data,
                Enum.Operation.Call,
                sender,
                derivationPath
            ),
            nonce: getNonce(self)
        });
        return proposeTransaction(self, params);
    }

    /// @notice Propose a transaction with a precomputed signature
    /// @dev    This can be used to propose transactions signed with a hardware wallet in a two-step process
    ///
    /// @param  self        The Safe client
    /// @param  to          The target address for the transaction
    /// @param  data        The data payload for the transaction
    /// @param  sender      The address of the account that is proposing the transaction
    /// @param  signature   The precomputed signature for the transaction, e.g. using {sign}
    /// @param  nonce       The nonce to use.
    /// @return txHash      The hash of the proposed Safe transaction
    function proposeTransactionWithSignature(
        Client storage self,
        address to,
        bytes memory data,
        address sender,
        bytes memory signature,
        uint256 nonce
    ) internal returns (bytes32 txHash) {
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: sender,
            signature: signature,
            nonce: nonce
        });
        txHash = proposeTransaction(self, params);
        return txHash;
    }

    function getProposeTransactionsTargetAndData(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas
    ) internal view returns (address, bytes memory) {
        if (targets.length != datas.length) {
            revert ArrayLengthsMismatch(targets.length, datas.length);
        }
        bytes1 operation = bytes1(uint8(Enum.Operation.Call));
        uint256 value = 0;
        bytes memory transactions;
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 dataLength = datas[i].length;
            transactions = abi.encodePacked(
                transactions,
                abi.encodePacked(
                    operation,
                    targets[i],
                    value,
                    dataLength,
                    datas[i]
                )
            );
        }
        address to = address(getMultiSendCallOnly(self, block.chainid));
        bytes memory data = abi.encodeCall(
            MultiSendCallOnly.multiSend,
            (transactions)
        );
        return (to, data);
    }

    function proposeTransactions(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender,
        string memory derivationPath
    ) internal returns (bytes32) {
        (address to, bytes memory data) = getProposeTransactionsTargetAndData(
            self,
            targets,
            datas
        );
        // using DelegateCall to preserve msg.sender across sub-calls
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.DelegateCall,
            sender: sender,
            signature: sign(
                self,
                to,
                data,
                Enum.Operation.DelegateCall,
                sender,
                derivationPath
            ),
            nonce: getNonce(self)
        });
        return proposeTransaction(self, params);
    }

    /// @notice Propose multiple transactions with a precomputed signature
    /// @dev    This can be used to propose transactions signed with a hardware wallet in a two-step process
    ///
    /// @param  self        The Safe client
    /// @param  targets     The list of target addresses for the transactions
    /// @param  datas       The list of data payloads for the transactions
    /// @param  sender      The address of the account that is proposing the transactions
    /// @param  signature   The precomputed signature for the batch of transactions, e.g. using {sign}
    /// @return txHash      The hash of the proposed Safe transaction
    function proposeTransactionsWithSignature(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender,
        bytes memory signature
    ) internal returns (bytes32 txHash) {
        (address to, bytes memory data) = getProposeTransactionsTargetAndData(
            self,
            targets,
            datas
        );
        // using DelegateCall to preserve msg.sender across sub-calls
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.DelegateCall,
            sender: sender,
            signature: signature,
            nonce: getNonce(self)
        });
        txHash = proposeTransaction(self, params);
        return txHash;
    }

    // ============================================================
    //                 EXEC TRANSACTION DATA BUILDERS
    // ============================================================

    function getExecTransactionData(
        Client storage self,
        address to,
        bytes memory data,
        address sender
    ) internal returns (bytes memory) {
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: sender,
            signature: sign(
                self,
                to,
                data,
                Enum.Operation.Call,
                sender,
                string("")
            ),
            nonce: getNonce(self)
        });
        return getExecTransactionData(self, params);
    }

    function getExecTransactionData(
        Client storage self,
        address to,
        bytes memory data,
        address sender,
        string memory derivationPath
    ) internal returns (bytes memory) {
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            sender: sender,
            signature: sign(
                self,
                to,
                data,
                Enum.Operation.Call,
                sender,
                derivationPath
            ),
            nonce: getNonce(self)
        });
        return getExecTransactionData(self, params);
    }

    function getExecTransactionsData(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender
    ) internal returns (bytes memory) {
        return
            getExecTransactionsData(self, targets, datas, sender, string(""));
    }

    function getExecTransactionsData(
        Client storage self,
        address[] memory targets,
        bytes[] memory datas,
        address sender,
        string memory derivationPath
    ) internal returns (bytes memory) {
        (address to, bytes memory data) = getProposeTransactionsTargetAndData(
            self,
            targets,
            datas
        );
        // using DelegateCall to preserve msg.sender across sub-calls
        ExecTransactionParams memory params = ExecTransactionParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.DelegateCall,
            sender: sender,
            signature: sign(
                self,
                to,
                data,
                Enum.Operation.DelegateCall,
                sender,
                derivationPath
            ),
            nonce: getNonce(self)
        });
        return getExecTransactionData(self, params);
    }

    function getExecTransactionData(
        Client storage,
        ExecTransactionParams memory params
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                ISafeSmartAccount.execTransaction,
                (
                    params.to,
                    0,
                    params.data,
                    params.operation,
                    0,
                    0,
                    0,
                    address(0),
                    payable(0),
                    params.signature
                )
            );
    }

    // ============================================================
    //                      SIGNING FUNCTIONS
    // ============================================================

    /// @notice Prepare the signature for a transaction, using a custom nonce
    ///
    /// @param  self            The Safe client
    /// @param  to              The target address for the transaction
    /// @param  data            The data payload for the transaction
    /// @param  operation       The operation to perform
    /// @param  sender          The address of the account that is signing the transaction
    /// @param  nonce           The nonce of the transaction
    /// @param  derivationPath  The derivation path for the transaction
    /// @return signature       The signature for the transaction
    function sign(
        Client storage self,
        address to,
        bytes memory data,
        Enum.Operation operation,
        address sender,
        uint256 nonce,
        string memory derivationPath
    ) internal returns (bytes memory) {
        if (bytes(derivationPath).length > 0) {
            string memory hardwareWallet = vm.envOr(
                "HARDWARE_WALLET",
                string("ledger")
            );

            // Trezor: sign raw hash (cast doesn't support EIP-712 --data for Trezor)
            if (
                keccak256(bytes(hardwareWallet)) == keccak256(bytes("trezor"))
            ) {
                bytes32 safeTxHash = getSafeTxHash(
                    self,
                    to,
                    0,
                    data,
                    operation,
                    nonce
                );

                console.log(
                    "proposing signature for tx hash:",
                    vm.toString(safeTxHash)
                );

                string[] memory inputs = new string[](7);
                inputs[0] = "cast";
                inputs[1] = "wallet";
                inputs[2] = "sign";
                inputs[3] = "--trezor";
                inputs[4] = "--mnemonic-derivation-path";
                inputs[5] = derivationPath;
                inputs[6] = vm.toString(safeTxHash);

                bytes memory output = vm.ffi(inputs);
                // Trezor uses eth_sign which adds prefix - Safe needs v+4 to know this
                // Signature format: r (32 bytes) || s (32 bytes) || v (1 byte)
                uint8 v = uint8(output[64]);
                output[64] = bytes1(v + 4);
                return output;
            }
            // Ledger: use EIP-712 typed data signing (fully supported)
            else {
                string[] memory inputs = new string[](8);
                inputs[0] = "cast";
                inputs[1] = "wallet";
                inputs[2] = "sign";
                inputs[3] = "--ledger";
                inputs[4] = "--mnemonic-derivation-path";
                inputs[5] = derivationPath;
                inputs[6] = "--data";
                inputs[7] = string.concat(
                    '{"domain":{"chainId":"',
                    vm.toString(block.chainid),
                    '","verifyingContract":"',
                    vm.toString(instance(self).safe),
                    '"},"message":{"to":"',
                    vm.toString(to),
                    '","value":"0","data":"',
                    vm.toString(data),
                    '","operation":',
                    vm.toString(uint8(operation)),
                    ',"baseGas":"0","gasPrice":"0","gasToken":"0x0000000000000000000000000000000000000000","refundReceiver":"0x0000000000000000000000000000000000000000","nonce":',
                    vm.toString(nonce),
                    ',"safeTxGas":"0"},"primaryType":"SafeTx","types":{"SafeTx":[{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"data","type":"bytes"},{"name":"operation","type":"uint8"},{"name":"safeTxGas","type":"uint256"},{"name":"baseGas","type":"uint256"},{"name":"gasPrice","type":"uint256"},{"name":"gasToken","type":"address"},{"name":"refundReceiver","type":"address"},{"name":"nonce","type":"uint256"}]}}'
                );

                bytes memory output = vm.ffi(inputs);
                return output;
            }
        } else {
            Signature memory sig;
            (sig.v, sig.r, sig.s) = vm.sign(
                sender,
                getSafeTxHash(self, to, 0, data, operation, nonce)
            );
            return abi.encodePacked(sig.r, sig.s, sig.v);
        }
    }

    /// @notice Prepare the signature for a transaction, using the nonce from the Safe
    function sign(
        Client storage self,
        address to,
        bytes memory data,
        Enum.Operation operation,
        address sender,
        string memory derivationPath
    ) internal returns (bytes memory) {
        return
            sign(
                self,
                to,
                data,
                operation,
                sender,
                getNonce(self),
                derivationPath
            );
    }
}
