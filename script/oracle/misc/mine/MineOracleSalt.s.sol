// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DERC20} from "src/DERC20.sol";

/**
 * @title MineOracleSalt
 * @notice Mine for a CREATE2 salt that produces an Oracle token address with:
 *         1. Last byte == 0x69
 *         2. Address < NOICE (0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69)
 *
 * @dev Uses `cast create2` via FFI for fast mining (Rust implementation)
 *
 *      Usage:
 *      1. Run: forge script script/oracle/misc/mine/MineOracleSalt.s.sol --ffi
 *      2. Copy the output ORACLE_SALT value
 *      3. Set env var: export ORACLE_SALT=0x...
 *      4. Run LaunchOracle.s.sol
 *
 *      Note: Requires --ffi flag for cast create2 execution
 */
contract MineOracleSalt is Script {
    // Base Mainnet addresses
    address constant AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
    address constant TOKEN_FACTORY = 0x4225C632b62622Bd7B0A3eC9745C0a866Ff94F6F;
    address constant NOICE = 0x9Cb41FD9dC6891BAe8187029461bfAADF6CC0C69;

    // Token configuration (must match LaunchOracle.s.sol)
    string constant NAME = "Oracle";
    string constant SYMBOL = "ORACLE";
    string constant TOKEN_URI =
        "ipfs://bafybeia3xdx3otq6fi7l2x5szaz5b6biex747gsyuyqi2tk3lzm66fdaiu";
    uint256 constant INITIAL_SUPPLY = 100_000_000_000 ether;

    function run() public returns (bytes32, address) {
        console2.log("=== Mine Oracle Salt ===");
        console2.log("Target: Address ending in 0x69 and < NOICE");
        console2.log("NOICE:", NOICE);
        console2.log("Token Factory:", TOKEN_FACTORY);
        console2.log("");

        // Compute the creation code hash
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(DERC20).creationCode,
                abi.encode(
                    NAME,
                    SYMBOL,
                    INITIAL_SUPPLY,
                    AIRLOCK,
                    AIRLOCK,
                    0,
                    0,
                    new address[](0),
                    new uint256[](0),
                    TOKEN_URI
                )
            )
        );

        console2.log("Init code hash:", vm.toString(initCodeHash));
        console2.log("");

        // Mine with pattern starting with 0 (always < 0x9C = NOICE)
        string[1] memory startPatterns = ["0"];

        for (uint256 i = 0; i < startPatterns.length; i++) {
            console2.log(
                "Attempting pattern: starts with",
                startPatterns[i],
                "and ends with 69"
            );

            (bytes32 salt, address predictedAddr) = mineSalt(
                initCodeHash,
                startPatterns[i],
                "69"
            );

            // Verify both conditions
            bool endsIn69 = uint160(predictedAddr) % 0x100 == 0x69;
            bool lessThanNoice = predictedAddr < NOICE;

            console2.log("  Found address:", predictedAddr);
            console2.log("  Ends in 0x69:", endsIn69);
            console2.log("  < NOICE:", lessThanNoice);

            if (endsIn69 && lessThanNoice) {
                console2.log("");
                console2.log("=== SALT FOUND! ===");
                console2.log("Salt:", vm.toString(salt));
                console2.log("Address:", predictedAddr);
                console2.log("");
                console2.log("=== Next Steps ===");
                console2.log("1. Set environment variable:");
                console2.log("   export ORACLE_SALT=", vm.toString(salt));
                console2.log("");
                console2.log("2. Run launch script:");
                console2.log(
                    "   forge script script/oracle/launch/LaunchOracle.s.sol \\"
                );
                console2.log("     --rpc-url $BASE_MAINNET_RPC_URL \\");
                console2.log("     --broadcast --private-key $PRIVATE_KEY");
                console2.log("");

                return (salt, predictedAddr);
            }

            console2.log(
                "  Does not satisfy both conditions, trying next pattern..."
            );
            console2.log("");
        }

        revert(
            "No matching salt found. Try running again or use different patterns."
        );
    }

    /**
     * @dev Mine salt using cast create2 (FFI)
     * @param initCodeHash The keccak256 hash of the creation code
     * @param startsWith Hex pattern the address should start with (without 0x)
     * @param endsWith Hex pattern the address should end with
     * @return salt The mined salt
     * @return expectedAddress The predicted address
     */
    function mineSalt(
        bytes32 initCodeHash,
        string memory startsWith,
        string memory endsWith
    ) internal returns (bytes32 salt, address expectedAddress) {
        // Build cast create2 command
        string[] memory args = new string[](10);
        args[0] = "cast";
        args[1] = "create2";
        args[2] = "--starts-with";
        args[3] = startsWith;
        args[4] = "--ends-with";
        args[5] = endsWith;
        args[6] = "--deployer";
        args[7] = vm.toString(TOKEN_FACTORY);
        args[8] = "--init-code-hash";
        args[9] = toHexStringNoPrefix(initCodeHash);

        // Execute cast create2
        bytes memory result = vm.ffi(args);
        string memory output = string(result);

        // Parse output
        // Format: "Address: 0x... Salt: 0x..."
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

        // Extract salt hex string (variable length, goes to end or newline)
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
