// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {InverseToken} from "./InverseToken.sol";
import {InverseMath} from "./libraries/InverseMath.sol";
import {IInverseMarket} from "./interfaces/IInverseMarket.sol";

/// @notice The canonical exact-input route. Each call performs exactly one unlock and one rebase.
contract InverseGateway is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IInverseMarket public immutable market;
    IPoolManager public immutable poolManager;
    bytes32 private callbackHash;

    error UnauthorizedCallback();
    error Expired();
    error InvalidRecipient();
    error Slippage();
    error SettlementMismatch();
    error NestedUnlock();

    constructor(IInverseMarket market_, IPoolManager manager_) {
        market = market_;
        poolManager = manager_;
    }

    function buy(uint256 quoteIn, uint256 minSharesOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sharesOut, uint256 settlementTokens, uint256 finalTokens)
    {
        IInverseMarket.Trade memory trade;
        (trade, finalTokens) = _execute(true, quoteIn, minSharesOut, recipient, deadline);
        return (trade.shares, trade.settlementTokens, finalTokens);
    }

    function sellShares(uint256 sharesIn, uint256 minQuoteOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 settlementTokens)
    {
        (IInverseMarket.Trade memory trade,) = _execute(false, sharesIn, minQuoteOut, recipient, deadline);
        return (trade.quote, trade.settlementTokens);
    }

    /// @notice Converts at the current committed index. Requires approveShares, like sellShares.
    function sellTokens(uint256 tokensIn, uint256 minQuoteOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 sharesIn)
    {
        sharesIn = market.token().sharesForTokens(tokensIn);
        (IInverseMarket.Trade memory trade,) = _execute(false, sharesIn, minQuoteOut, recipient, deadline);
        return (trade.quote, trade.shares);
    }

    /// @notice Exact full exit, including shares hidden by display rounding.
    function sellAll(uint256 minQuoteOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 sharesIn)
    {
        sharesIn = market.token().sharesOf(msg.sender);
        (IInverseMarket.Trade memory trade,) = _execute(false, sharesIn, minQuoteOut, recipient, deadline);
        return (trade.quote, trade.shares);
    }

    function _execute(bool isBuy, uint256 amount, uint256 minimum, address recipient, uint256 deadline)
        private
        returns (IInverseMarket.Trade memory trade, uint256 finalTokens)
    {
        if (block.timestamp > deadline) revert Expired();
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(market)
                || recipient == address(poolManager) || recipient == address(market.token())
        ) revert InvalidRecipient();
        if (poolManager.isUnlocked()) revert NestedUnlock();
        trade = market.prepare(isBuy, amount);
        if ((isBuy ? trade.shares : trade.quote) < minimum) revert Slippage();
        bytes memory data = abi.encode(msg.sender, recipient, trade);
        callbackHash = keccak256(data);
        poolManager.unlock(data);
        if (callbackHash != bytes32(0) || poolManager.isUnlocked()) revert SettlementMismatch();
        finalTokens = market.finalize(msg.sender, recipient);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || callbackHash == bytes32(0)
                || keccak256(data) != callbackHash
        ) {
            revert UnauthorizedCallback();
        }
        delete callbackHash;
        (address payer, address recipient, IInverseMarket.Trade memory trade) =
            abi.decode(data, (address, address, IInverseMarket.Trade));
        InverseToken inverse = market.token();
        IERC20 quote = market.quoteToken();
        Currency input = Currency.wrap(trade.buy ? address(quote) : address(inverse));
        uint256 inputAmount = trade.buy ? trade.quote : trade.settlementTokens;
        uint256 managerQuoteBefore = quote.balanceOf(address(poolManager));
        uint256 recipientBefore = trade.buy ? inverse.sharesOf(recipient) : quote.balanceOf(recipient);

        // Prefund so hook.take never relies on liquidity from unrelated pools.
        poolManager.sync(input);
        if (trade.buy) {
            uint256 payerBefore = quote.balanceOf(payer);
            quote.safeTransferFrom(payer, address(poolManager), trade.quote);
            if (quote.balanceOf(payer) + trade.quote != payerBefore) revert SettlementMismatch();
        } else {
            inverse.transferSharesFrom(payer, address(poolManager), trade.shares);
        }
        if (poolManager.settle() != inputAmount) revert SettlementMismatch();

        _swapAndTake(trade, recipient);
        uint256 recipientAfter = trade.buy ? inverse.sharesOf(recipient) : quote.balanceOf(recipient);
        if (
            recipientAfter != recipientBefore + (trade.buy ? trade.shares : trade.quote)
                || inverse.sharesOf(address(poolManager)) != 0
                || quote.balanceOf(address(poolManager)) != managerQuoteBefore
        ) revert SettlementMismatch();
        return bytes("");
    }

    function _swapAndTake(IInverseMarket.Trade memory trade, address recipient) private {
        PoolKey memory key = market.poolKey();
        address inverse = address(market.token());
        address quote = address(market.quoteToken());
        uint256 inputAmount = trade.buy ? trade.quote : trade.settlementTokens;
        uint256 outputAmount = trade.buy ? trade.settlementTokens : trade.quote;
        bool zeroForOne = Currency.unwrap(key.currency0) == (trade.buy ? quote : inverse);
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (
            inputDelta != -InverseMath.toInt128(inputAmount)
                || outputDelta != InverseMath.toInt128(outputAmount)
        ) {
            revert SettlementMismatch();
        }
        poolManager.take(Currency.wrap(trade.buy ? inverse : quote), recipient, outputAmount);
    }
}
