// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ImprintHookData } from "../src/libraries/ImprintHookData.sol";

contract ImprintHookDataHarness {
    function decode(bytes calldata encoded) external pure returns (ImprintHookData.ProtectedSwapData memory) {
        return ImprintHookData.decode(encoded);
    }
}

contract ImprintHookDataTest is Test {
    ImprintHookDataHarness internal harness;

    function setUp() public {
        harness = new ImprintHookDataHarness();
    }

    function validData() internal pure returns (ImprintHookData.ProtectedSwapData memory) {
        return ImprintHookData.ProtectedSwapData({
            trader: address(0xA11CE), bondToken: address(0xB0AD), bondAmount: 25 ether, nonce: 7
        });
    }

    function test_roundTripPreservesProtectedSwapData() public view {
        bytes memory encoded = ImprintHookData.encode(validData());

        ImprintHookData.ProtectedSwapData memory decoded = harness.decode(encoded);

        assertEq(decoded.trader, address(0xA11CE));
        assertEq(decoded.bondToken, address(0xB0AD));
        assertEq(decoded.bondAmount, 25 ether);
        assertEq(decoded.nonce, 7);
    }

    function test_encodingUsesFixedLength() public pure {
        assertEq(ImprintHookData.encode(validData()).length, 160);
    }

    function test_rejectsWrongLength() public {
        vm.expectRevert(abi.encodeWithSelector(ImprintHookData.InvalidHookDataLength.selector, 32));

        harness.decode(abi.encode(uint256(1)));
    }

    function test_rejectsWrongSchema() public {
        bytes memory encoded = abi.encode(bytes4(0x42414431), validData());

        vm.expectRevert(abi.encodeWithSelector(ImprintHookData.InvalidHookDataSchema.selector, bytes4(0x42414431)));

        harness.decode(encoded);
    }

    function test_rejectsZeroTraderWhenEncoding() public {
        ImprintHookData.ProtectedSwapData memory data = validData();
        data.trader = address(0);

        vm.expectRevert(ImprintHookData.InvalidTrader.selector);
        this.exposedEncode(data);
    }

    function test_rejectsZeroBondTokenWhenEncoding() public {
        ImprintHookData.ProtectedSwapData memory data = validData();
        data.bondToken = address(0);

        vm.expectRevert(ImprintHookData.InvalidBondToken.selector);
        this.exposedEncode(data);
    }

    function exposedEncode(ImprintHookData.ProtectedSwapData memory data) external pure returns (bytes memory) {
        return ImprintHookData.encode(data);
    }
}
