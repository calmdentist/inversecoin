// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {InverseToken} from "./InverseToken.sol";
import {InverseGateway} from "./InverseGateway.sol";
import {InverseMath} from "./libraries/InverseMath.sol";
import {IInverseMarket} from "./interfaces/IInverseMarket.sol";
import {RejectingHook} from "./base/RejectingHook.sol";

/// @notice A single, permanently seeded share-space constant-product market using v4 custom accounting.
/// @dev No owner withdrawals, discretionary rebases, new shares, or mutable fee configuration.
contract InverseHook is RejectingHook, IInverseMarket {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint256 public constant RAY = 1e27;
    IPoolManager public immutable poolManager;
    IERC20 public immutable quoteToken;
    InverseToken public immutable token;
    InverseGateway public immutable gateway;
    address public immutable seeder;
    uint256 public immutable initialShares;
    uint256 public immutable initialQuote;
    uint256 public immutable quoteScale;
    uint256 public immutable referencePriceRay;
    uint24 public immutable feePpm;
    PoolId public immutable poolId;

    uint256 public reserveShares;
    uint256 public reserveQuote;
    uint256 public sequence;
    bool public initialized;
    // 0 = idle, 1 = prepared, 2 = settlement executed. Committed reserves stay frozen until finalize.
    uint8 public phase;
    Trade private pending;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidPhase();
    error InvalidPool();
    error InvalidSwap();
    error SettlementMismatch();

    event MarketInitialized(
        PoolId indexed poolId,
        address token,
        address gateway,
        uint256 shares,
        uint256 quote,
        uint256 referencePriceRay,
        uint24 feePpm
    );
    event EconomicSwap(
        uint256 indexed sequence,
        address indexed payer,
        address indexed recipient,
        bool buy,
        uint256 shares,
        uint256 quote,
        uint256 settlementTokens,
        uint256 finalTokens,
        uint256 feeInput,
        uint256 indexRay,
        uint256 sharePriceRay,
        uint256 tokenPriceRay
    );
    event ReservesUpdated(uint256 indexed sequence, uint256 shares, uint256 quote);

    constructor(
        IPoolManager manager_,
        IERC20Metadata quote_,
        address seeder_,
        uint256 shares_,
        uint256 quoteAmount_,
        uint24 feePpm_
    ) {
        if (
            address(manager_).code.length == 0 || address(quote_).code.length == 0 || seeder_ == address(0)
                || shares_ < 1e18 || shares_ > 1e30 || quoteAmount_ == 0
                || quoteAmount_ > InverseMath.MAX_RESERVE || feePpm_ >= 1_000_000
        ) revert InvalidConfiguration();
        uint8 decimals_ = quote_.decimals();
        if (decimals_ < 6 || decimals_ > 18) revert InvalidConfiguration();
        poolManager = manager_;
        quoteToken = IERC20(address(quote_));
        seeder = seeder_;
        initialShares = shares_;
        initialQuote = quoteAmount_;
        quoteScale = 10 ** (18 - decimals_);
        referencePriceRay = FullMath.mulDiv(quoteAmount_, quoteScale * RAY, shares_);
        if (referencePriceRay < 1e18 || referencePriceRay > 1e36) revert InvalidConfiguration();
        feePpm = feePpm_;
        gateway = new InverseGateway(IInverseMarket(address(this)), manager_);
        token = new InverseToken(address(this), address(gateway), address(manager_), shares_);
        poolId = poolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.beforeDonate = true;
        p.beforeSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        bool token0 = address(token) < address(quoteToken);
        return PoolKey({
            currency0: Currency.wrap(token0 ? address(token) : address(quoteToken)),
            currency1: Currency.wrap(token0 ? address(quoteToken) : address(token)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(this))
        });
    }

    /// @notice Seed once. All initial shares and quote liquidity are permanently committed.
    function initialize() external {
        if (msg.sender != seeder) revert Unauthorized();
        if (initialized || phase != 0 || poolManager.isUnlocked()) revert InvalidPhase();
        initialized = true;
        phase = 1;
        uint256 beforeBalance = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), initialQuote);
        if (quoteToken.balanceOf(address(this)) != beforeBalance + initialQuote) revert SettlementMismatch();
        reserveShares = initialShares;
        reserveQuote = initialQuote;
        bool token0 = address(token) < address(quoteToken);
        uint256 numerator = token0 ? initialQuote : initialShares;
        uint256 denominator = token0 ? initialShares : initialQuote;
        uint160 sqrtPriceX96 = uint160(Math.sqrt(FullMath.mulDiv(numerator, 1 << 128, denominator)) << 32);
        poolManager.initialize(poolKey(), sqrtPriceX96);
        phase = 0;
        emit MarketInitialized(
            poolId, address(token), address(gateway), initialShares, initialQuote, referencePriceRay, feePpm
        );
        emit ReservesUpdated(0, initialShares, initialQuote);
    }

    /// @return trade A bounded, exact-input quote in shares and raw quote units.
    function preview(bool isBuy, uint256 amount) public view returns (Trade memory trade) {
        if (!initialized || phase != 0) revert InvalidPhase();
        trade.buy = isBuy;
        if (isBuy) {
            trade.quote = amount;
            (trade.shares, trade.feeInput) =
                InverseMath.amountOut(amount, reserveQuote, reserveShares, feePpm);
            trade.nextShares = reserveShares - trade.shares;
            trade.nextQuote = reserveQuote + amount;
        } else {
            if (amount > initialShares - reserveShares) revert InverseMath.InvalidAmount();
            trade.shares = amount;
            (trade.quote, trade.feeInput) = InverseMath.amountOut(amount, reserveShares, reserveQuote, feePpm);
            trade.nextShares = reserveShares + amount;
            trade.nextQuote = reserveQuote - trade.quote;
        }
        trade.nextIndex = InverseMath.index(trade.nextShares, trade.nextQuote, initialShares, initialQuote);
        trade.settlementTokens = token.tokensForShares(trade.shares);
        InverseMath.toInt128(trade.quote);
        InverseMath.toInt128(trade.settlementTokens);
    }

    function prepare(bool isBuy, uint256 amount) external returns (Trade memory trade) {
        if (msg.sender != address(gateway)) revert Unauthorized();
        if (poolManager.isUnlocked()) revert InvalidPhase();
        trade = preview(isBuy, amount);
        pending = trade;
        phase = 1;
        token.beginSettlement();
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager) || sender != address(gateway)) {
            revert Unauthorized();
        }
        if (phase != 1) revert InvalidPhase();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
        Trade memory trade = pending;
        bool inputIs0 = Currency.unwrap(key.currency0) == (trade.buy ? address(quoteToken) : address(token));
        uint256 input = trade.buy ? trade.quote : trade.settlementTokens;
        uint256 output = trade.buy ? trade.settlementTokens : trade.quote;
        if (params.amountSpecified != -int256(input) || params.zeroForOne != inputIs0 || hookData.length != 0)
        {
            revert InvalidSwap();
        }
        phase = 2;
        if (trade.buy) {
            uint256 beforeQuote = quoteToken.balanceOf(address(this));
            poolManager.take(Currency.wrap(address(quoteToken)), address(this), trade.quote);
            if (quoteToken.balanceOf(address(this)) != beforeQuote + trade.quote) {
                revert SettlementMismatch();
            }
            poolManager.sync(Currency.wrap(address(token)));
            token.transferShares(address(poolManager), trade.shares);
        } else {
            uint256 beforeShares = token.sharesOf(address(this));
            poolManager.take(Currency.wrap(address(token)), address(this), trade.settlementTokens);
            if (token.sharesOf(address(this)) != beforeShares + trade.shares) revert SettlementMismatch();
            poolManager.sync(Currency.wrap(address(quoteToken)));
            uint256 beforeQuote = quoteToken.balanceOf(address(this));
            quoteToken.safeTransfer(address(poolManager), trade.quote);
            if (quoteToken.balanceOf(address(this)) + trade.quote != beforeQuote) {
                revert SettlementMismatch();
            }
        }
        if (poolManager.settle() != output) revert SettlementMismatch();
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(InverseMath.toInt128(input), -InverseMath.toInt128(output)),
            0
        );
    }

    function finalize(address payer, address recipient) external returns (uint256 finalTokens) {
        if (msg.sender != address(gateway)) revert Unauthorized();
        if (phase != 2 || poolManager.isUnlocked()) revert InvalidPhase();
        Trade memory trade = pending;
        if (
            token.sharesOf(address(this)) < trade.nextShares
                || quoteToken.balanceOf(address(this)) < trade.nextQuote
                || token.sharesOf(address(poolManager)) != 0
        ) revert SettlementMismatch();
        reserveShares = trade.nextShares;
        reserveQuote = trade.nextQuote;
        delete pending;
        token.finishSettlement(trade.nextIndex);
        phase = 0;
        finalTokens = token.tokensForShares(trade.shares);
        uint256 id = ++sequence;
        emit EconomicSwap(
            id,
            payer,
            recipient,
            trade.buy,
            trade.shares,
            trade.quote,
            trade.settlementTokens,
            finalTokens,
            trade.feeInput,
            trade.nextIndex,
            sharePriceRay(),
            tokenPriceRay()
        );
        emit ReservesUpdated(id, reserveShares, reserveQuote);
    }

    function sharePriceRay() public view returns (uint256) {
        if (!initialized) revert InvalidPhase();
        return FullMath.mulDiv(reserveQuote, quoteScale * RAY, reserveShares);
    }

    function tokenPriceRay() public view returns (uint256) {
        return FullMath.mulDiv(sharePriceRay(), RAY, token.indexRay());
    }

    /// @notice Quote value (18 decimals), before liquidation impact or fees. Never a dollar oracle.
    function spotValue(address account) external view returns (uint256) {
        return FullMath.mulDiv(token.sharesOf(account), sharePriceRay(), RAY);
    }

    /// @notice Unsolicited donations are segregated and cannot be withdrawn or traded as reserves.
    function surplus() external view returns (uint256 shares, uint256 quote) {
        if (phase != 0) revert InvalidPhase();
        return
            (
                token.sharesOf(address(this)) - reserveShares,
                quoteToken.balanceOf(address(this)) - reserveQuote
            );
    }
}
