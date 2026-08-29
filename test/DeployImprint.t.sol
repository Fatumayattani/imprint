// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { DeployImprint } from "../script/DeployImprint.s.sol";

contract DeployImprintTest is Test {
    function test_rejectsPoolManagerWithoutCode() public {
        address emptyAddress = address(0xBEEF);

        vm.setEnv("POOL_MANAGER", vm.toString(emptyAddress));

        DeployImprint deployment = new DeployImprint();

        vm.expectRevert(abi.encodeWithSelector(DeployImprint.PoolManagerHasNoCode.selector, emptyAddress));

        deployment.run();
    }
}
