// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InverseToken} from "../InverseToken.sol";

interface IInverseMarket {
    struct Trade {
        bool buy;
        uint256 shares;
        uint256 quote;
        uint256 settlementTokens;
        uint256 nextShares;
        uint256 nextQuote;
        uint256 nextIndex;
        uint256 feeInput;
    }

    function poolManager() external view returns (IPoolManager);
    function quoteToken() external view returns (IERC20);
    function token() external view returns (InverseToken);
    function poolKey() external view returns (PoolKey memory);
    function prepare(bool buy, uint256 amount) external returns (Trade memory);
    function finalize(address payer, address recipient) external returns (uint256 finalTokens);
}
