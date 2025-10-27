// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NoiceLaunchpad} from "src/NoiceLaunchpad.sol";

/**
 * @title MineNoiceLaunchpadSalt
 * @notice Mine for a CREATE2 salt that produces a NoiceLaunchpad address with desired pattern
 *
 * @dev Uses `cast create2` via FFI for fast mining (Rust implementation)
 *
 *      Usage:
 *      1. Set DEPLOYER_ADDRESS env var (address that will deploy)
 *      2. Set START_PATTERN env var (e.g., "0" or "dead")
 *      3. Set END_PATTERN env var (e.g., "69" or "beef")
 *      4. Run: forge script script/oracle/misc/mine/MineNoiceLaunchpadSalt.s.sol --ffi
 *      5. Copy the output LAUNCHPAD_SALT value
 *      6. Use in deployment script with the salt
 *
 *      Note: Requires --ffi flag for cast create2 execution
 *
 *      Example patterns:
 *      - START_PATTERN=0 END_PATTERN=69 → Address like 0x0...69
 *      - START_PATTERN=dead END_PATTERN=beef → Address like 0xdead...beef
 */
contract MineNoiceLaunchpadSalt is Script {
    // Base Mainnet addresses (for init code hash)
    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant SABLIER_LOCKUP = 0xb5D78DD3276325f5FAF3106Cc4Acc56E28e0Fe3B;
    address constant SABLIER_BATCH_LOCKUP = 0xC26CdAFd6ec3c91AD9aEeB237Ee1f37205ED26a4;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function run() public returns (bytes32, address) {
        // Get deployer address from env
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // Get pattern preferences from env (with defaults)
        string memory startPattern = vm.envOr("START_PATTERN", string("0"));
        string memory endPattern = vm.envOr("END_PATTERN", string(""));

        console2.log("=== Mine NoiceLaunchpad Salt ===");
        console2.log("Deployer:", deployer);
        console2.log("Target: Address starting with", startPattern);
        if (bytes(endPattern).length > 0) {
            console2.log("        and ending with", endPattern);
        }
        console2.log("");

        // Compute the init code hash for NoiceLaunchpad with constructor args
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(NoiceLaunchpad).creationCode,
                abi.encode(
                    AIRLOCK,
                    UNIVERSAL_ROUTER,
                    SABLIER_LOCKUP,
                    SABLIER_BATCH_LOCKUP,
                    POOL_MANAGER,
                    deployer // owner
                )
            )
        );

        console2.log("Init code hash:", vm.toString(initCodeHash));
        console2.log("");

        console2.log("Mining... (this may take a while)");
        console2.log("");

        // Mine salt using cast create2
        (bytes32 salt, address predictedAddr) = mineSalt(
            initCodeHash,
            deployer,
            startPattern,
            endPattern
        );

        console2.log("");
        console2.log("=== SALT FOUND! ===");
        console2.log("Salt:", vm.toString(salt));
        console2.log("Address:", predictedAddr);
        console2.log("");
        console2.log("=== Next Steps ===");
        console2.log("1. Update deployment script with this salt");
        console2.log("2. Deploy NoiceLaunchpad with:");
        console2.log("   bytes32 salt =", vm.toString(salt), ";");
        console2.log("   new NoiceLaunchpad{salt: salt}(");
        console2.log("     Airlock(payable(AIRLOCK)),");
        console2.log("     UniversalRouter(payable(UNIVERSAL_ROUTER)),");
        console2.log("     ISablierLockup(SABLIER_LOCKUP),");
        console2.log("     ISablierBatchLockup(SABLIER_BATCH_LOCKUP),");
        console2.log("     IPoolManager(POOL_MANAGER),");
        console2.log("     deployer");
        console2.log("   );");
        console2.log("");

        return (salt, predictedAddr);
    }

    /**
     * @dev Mine salt using cast create2 (FFI)
     * @param initCodeHash The keccak256 hash of the creation code with constructor args
     * @param deployer The address that will deploy the contract
     * @param startsWith Hex pattern the address should start with (without 0x)
     * @param endsWith Hex pattern the address should end with (optional)
     * @return salt The mined salt
     * @return expectedAddress The predicted address
     */
    function mineSalt(
        bytes32 initCodeHash,
        address deployer,
        string memory startsWith,
        string memory endsWith
    ) internal returns (bytes32 salt, address expectedAddress) {
        // Build cast create2 command
        uint256 argsCount = bytes(endsWith).length > 0 ? 10 : 8;
        string[] memory args = new string[](argsCount);

        args[0] = "cast";
        args[1] = "create2";
        args[2] = "--starts-with";
        args[3] = startsWith;

        uint256 nextIdx = 4;
        if (bytes(endsWith).length > 0) {
            args[nextIdx++] = "--ends-with";
            args[nextIdx++] = endsWith;
        }

        args[nextIdx++] = "--deployer";
        args[nextIdx++] = vm.toString(deployer);
        args[nextIdx++] = "--init-code-hash";
        args[nextIdx] = toHexStringNoPrefix(initCodeHash);

        // Execute cast create2
        bytes memory result = vm.ffi(args);
        string memory output = string(result);

        // Parse output
        (expectedAddress, salt) = parseCreate2Output(output);
    }

    /**
     * @dev Parse output from cast create2
     * @param output The raw output string
     * @return addr The parsed address
     * @return salt The parsed salt
     */
    function parseCreate2Output(
        string memory output
    ) internal pure returns (address addr, bytes32 salt) {
        // Find "Address: " and extract address
        bytes memory outputBytes = bytes(output);
        uint256 addrIndex = findSubstring(outputBytes, "Address: ");
        require(
            addrIndex != type(uint256).max,
            "Could not find Address in output"
        );

        // Address is 42 characters after "Address: " (0x + 40 hex chars)
        bytes memory addrBytes = new bytes(42);
        for (uint256 i = 0; i < 42; i++) {
            addrBytes[i] = outputBytes[addrIndex + 9 + i];
        }
        addr = vm.parseAddress(string(addrBytes));

        // Find "Salt: " and extract salt
        uint256 saltIndex = findSubstring(outputBytes, "Salt: ");
        require(
            saltIndex != type(uint256).max,
            "Could not find Salt in output"
        );

        // Extract salt hex string
        bytes memory saltBytes = new bytes(66); // 0x + 64 hex chars
        uint256 saltLen = 0;
        for (
            uint256 i = saltIndex + 6;
            i < outputBytes.length && saltLen < 66;
            i++
        ) {
            if (outputBytes[i] == 0x0a || outputBytes[i] == 0x0d) break; // newline
            saltBytes[saltLen++] = outputBytes[i];
        }

        // Resize saltBytes to actual length
        bytes memory trimmedSalt = new bytes(saltLen);
        for (uint256 i = 0; i < saltLen; i++) {
            trimmedSalt[i] = saltBytes[i];
        }

        salt = bytes32(vm.parseUint(string(trimmedSalt)));
    }

    /**
     * @dev Find substring in bytes
     * @param haystack The bytes to search in
     * @param needle The string to search for
     * @return index The index of the first occurrence, or type(uint256).max if not found
     */
    function findSubstring(
        bytes memory haystack,
        string memory needle
    ) internal pure returns (uint256) {
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length > haystack.length) return type(uint256).max;

        for (uint256 i = 0; i <= haystack.length - needleBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystack[i + j] != needleBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }

        return type(uint256).max;
    }

    /**
     * @dev Convert bytes32 to hex string without 0x prefix
     * @param value The bytes32 value
     * @return The hex string
     */
    function toHexStringNoPrefix(
        bytes32 value
    ) internal pure returns (string memory) {
        bytes memory buffer = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            buffer[i * 2] = toHexChar(uint8(value[i]) / 16);
            buffer[i * 2 + 1] = toHexChar(uint8(value[i]) % 16);
        }
        return string(buffer);
    }

    /**
     * @dev Convert a uint8 to a hex character
     * @param value The uint8 value (0-15)
     * @return The hex character
     */
    function toHexChar(uint8 value) internal pure returns (bytes1) {
        if (value < 10) {
            return bytes1(uint8(48 + value)); // 0-9
        } else {
            return bytes1(uint8(87 + value)); // a-f
        }
    }
}
