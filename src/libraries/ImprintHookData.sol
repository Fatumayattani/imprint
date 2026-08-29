// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Imprint Hook Data
/// @notice Versioned encoding for authenticated protected-swap metadata.
library ImprintHookData {
    bytes4 internal constant SCHEMA = 0x494d5031;
    uint256 internal constant ENCODED_LENGTH = 160;

    error InvalidHookDataLength(uint256 length);
    error InvalidHookDataSchema(bytes4 schema);
    error InvalidTrader();
    error InvalidBondToken();

    struct ProtectedSwapData {
        address trader;
        address bondToken;
        uint256 bondAmount;
        uint256 nonce;
    }

    function encode(ProtectedSwapData memory data) internal pure returns (bytes memory) {
        _validate(data);
        return abi.encode(SCHEMA, data);
    }

    function decode(bytes calldata encoded) internal pure returns (ProtectedSwapData memory data) {
        if (encoded.length != ENCODED_LENGTH) {
            revert InvalidHookDataLength(encoded.length);
        }

        bytes4 schema;
        (schema, data) = abi.decode(encoded, (bytes4, ProtectedSwapData));

        if (schema != SCHEMA) {
            revert InvalidHookDataSchema(schema);
        }

        _validate(data);
    }

    function _validate(ProtectedSwapData memory data) private pure {
        if (data.trader == address(0)) revert InvalidTrader();
        if (data.bondToken == address(0)) revert InvalidBondToken();
    }
}
