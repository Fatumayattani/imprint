// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FeeOnTransferToken is ERC20 {
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant BPS = 10_000;

    constructor() ERC20("Fee Token", "FEE") { }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount * FEE_BPS / BPS;
            super._update(from, address(0), fee);
            amount -= fee;
        }

        super._update(from, to, amount);
    }
}
