// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IUniversalInverseRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IInversePermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Universal Router 2.1.1/2.2.0: V4_SWAP with exact-input single, SETTLE_ALL, TAKE_ALL.
library RouterCall {
    address internal constant ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    struct Single {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function encode(PoolKey memory key, Currency input, uint256 amount, uint256 minimum)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        require(
            amount > 0 && amount <= type(uint128).max && minimum <= type(uint128).max, "router amount bounds"
        );
        bool direction = Currency.unwrap(key.currency0) == Currency.unwrap(input);
        require(direction || Currency.unwrap(key.currency1) == Currency.unwrap(input), "input outside pool");
        bytes[] memory actions = new bytes[](3);
        actions[0] = abi.encode(Single(key, direction, uint128(amount), uint128(minimum), 0, ""));
        actions[1] = abi.encode(input, amount);
        actions[2] = abi.encode(direction ? key.currency1 : key.currency0, minimum);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", actions);
        commands = hex"10";
    }
}
