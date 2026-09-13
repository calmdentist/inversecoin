// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockQuote is ERC20 {
    uint8 private immutable quoteDecimals;

    constructor(uint8 decimals_) ERC20("Mock Dollar", "MUSD") {
        quoteDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return quoteDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
