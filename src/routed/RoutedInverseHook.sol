// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {InverseMath} from "../libraries/InverseMath.sol";
import {RoutedInverseToken, IRoutedInverseSettlement} from "./RoutedInverseToken.sol";

/// @notice Native-liquidity inverse market with fixed ownership and generic exact-input settlement.
/// @dev Fixed seeder owns the entire native position and may close/recover it. No external LPs,
/// additional LP deposits, arbitrary rebases, share minting, or exact-output trades.
/// Quote currency must be a trusted, non-rebasing, exact-transfer token (WETH on Robinhood).
/// INVERSE protocol fees require a permissionless V4FeeAdapter-compatible controller so they
/// can be collected before each rebase; WETH protocol fees accrue normally in PoolManager.
contract RoutedInverseHook is IHooks, IUnlockCallback, IRoutedInverseSettlement {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant RAY = 1e27;
    uint24 public constant FEE_PPM = 3000;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint256 private constant NET_FEE = FEE_DENOMINATOR - FEE_PPM;
    uint8 private constant IDLE = 0;
    uint8 private constant MAINTENANCE = 1;
    uint8 private constant CORE_SWAP = 2;
    uint8 private constant USER_SETTLEMENT = 3;
    uint8 private constant FINALIZING = 4;
    bytes32 private constant PENDING_TRADE_SLOT = keccak256("inverse.routed.pending-trade.v1");
    // Trade consists of fourteen ABI-sized memory words; it never survives a transaction.
    uint256 private constant TRADE_BYTES = 448;
    uint256 public constant ROUNDING_SEED = 1_000_000;
    uint256 public constant MAX_CUSTODY_LOSS = 32;
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    IPoolManager public immutable poolManager;
    IERC20 public immutable quoteToken;
    RoutedInverseToken public immutable token;
    address public immutable seeder;
    uint256 public immutable initialShares;
    uint256 public immutable initialQuote;
    PoolId public immutable poolId;
    uint256 public reserveShares;
    uint256 public reserveQuote;
    uint256 public nativeQuote;
    uint256 public roundingQuote;
    uint256 public sequence;
    uint128 public liquidity;
    bool public initialized;
    bool public closed;
    // IDLE -> MAINTENANCE -> IDLE, or IDLE -> CORE_SWAP -> USER_SETTLEMENT -> FINALIZING -> IDLE.
    // A prepaid sell skips USER_SETTLEMENT because its input is already escrowed.
    uint8 public phase;
    address private pendingRouter;
    int128 private outputCorrection;
    uint160 private previousSqrt;
    bool public prepaymentGuard;
    bool private prepaidTrade;

    struct Trade {
        bool buy;
        uint256 input;
        uint256 shares;
        uint256 quote;
        uint256 nextShares;
        uint256 nextQuote;
        uint256 nextIndex;
        uint256 nativeInput;
        uint256 output;
        uint256 inputClaim;
        uint256 virtualInverse;
        uint256 virtualQuote;
        uint256 protocolInput;
        uint256 protocolBefore;
    }

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidPhase();
    error InvalidPool();
    error UnsupportedOperation();
    error InvalidSwap();
    error SettlementMismatch();
    error RoundingLimit();
    error PriceDirection();
    error Slippage();

    event MarketInitialized(PoolId indexed poolId, address token, uint256 shares, uint256 quote);
    event EconomicSwap(
        uint256 indexed sequence,
        address indexed router,
        bool buy,
        uint256 shares,
        uint256 quote,
        uint256 indexRay,
        uint256 inversePriceRay
    );
    event RoundingUsed(uint256 quoteLoss, uint256 remaining);
    event RoundingFunded(address indexed payer, uint256 amount, uint256 remaining);
    event MarketClosed(address indexed recipient, uint256 shares, uint256 quote);

    constructor(
        IPoolManager manager_,
        IERC20Metadata quote_,
        address seeder_,
        uint256 shares_,
        uint256 seed_
    ) {
        if (
            address(manager_).code.length == 0 || address(quote_).code.length == 0 || quote_.decimals() != 18
                || seeder_ == address(0) || shares_ < 1e18 || shares_ > 1e30 || seed_ < 1e12
                || seed_ > InverseMath.MAX_RESERVE || seed_ >= shares_
        ) revert InvalidConfiguration();
        poolManager = manager_;
        quoteToken = IERC20(address(quote_));
        seeder = seeder_;
        initialShares = shares_;
        initialQuote = seed_;
        token = new RoutedInverseToken(address(manager_), shares_);
        poolId = poolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeDonate = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        bool inverse0 = address(token) < address(quoteToken);
        return PoolKey(
            Currency.wrap(inverse0 ? address(token) : address(quoteToken)),
            Currency.wrap(inverse0 ? address(quoteToken) : address(token)),
            FEE_PPM,
            60,
            IHooks(address(this))
        );
    }

    function initialize() external {
        if (msg.sender != seeder) revert Unauthorized();
        if (initialized || phase != IDLE || poolManager.isUnlocked()) revert InvalidPhase();
        phase = MAINTENANCE;
        initialized = true;
        reserveShares = initialShares;
        reserveQuote = initialQuote;
        roundingQuote = ROUNDING_SEED;
        uint256 beforeBalance = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), initialQuote + ROUNDING_SEED);
        if (quoteToken.balanceOf(address(this)) != beforeBalance + initialQuote + ROUNDING_SEED) {
            revert SettlementMismatch();
        }
        poolManager.initialize(poolKey(), _sqrt(initialShares, initialQuote));
        poolManager.unlock(abi.encode(false));
        emit MarketInitialized(poolId, address(token), initialShares, initialQuote);
    }

    /// @notice Donate quote to the rounding buffer without changing LP ownership or the price curve.
    /// @dev Unused funds are part of the seeder's eventual full withdrawal. No claim is issued to the donor.
    function fundRounding(uint256 amount) external {
        if (!initialized || closed || phase != IDLE || poolManager.isUnlocked()) revert InvalidPhase();
        if (amount == 0 || amount > InverseMath.MAX_RESERVE - roundingQuote) revert InvalidConfiguration();
        phase = MAINTENANCE;
        uint256 beforeBalance = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        if (quoteToken.balanceOf(address(this)) != beforeBalance + amount) revert SettlementMismatch();
        roundingQuote += amount;
        phase = IDLE;
        emit RoundingFunded(msg.sender, amount, roundingQuote);
    }

    /// @notice Recover the seeder's whole position and its fees; no trader's shares are sold.
    /// @dev Closing permanently disables trading. The denomination remains transferable/frozen afterward.
    function withdrawAll(address recipient, uint256 minQuote, uint256 deadline)
        external
        returns (uint256 shares, uint256 quote)
    {
        if (msg.sender != seeder) revert Unauthorized();
        if (!initialized || closed || phase != IDLE || poolManager.isUnlocked()) revert InvalidPhase();
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(token)
                || recipient == address(poolManager) || block.timestamp > deadline
        ) revert InvalidConfiguration();
        phase = MAINTENANCE;
        closed = true;
        poolManager.unlock(abi.encode(true));
        shares = token.custodiedShares();
        quote = quoteToken.balanceOf(address(this));
        if (quote < minQuote) revert Slippage();
        reserveShares = 0;
        reserveQuote = 0;
        roundingQuote = 0;
        token.transferShares(recipient, shares);
        quoteToken.safeTransfer(recipient, quote);
        emit MarketClosed(recipient, shares, quote);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || phase != MAINTENANCE) revert Unauthorized();
        token.beginLiquidity();
        if (abi.decode(data, (bool))) {
            // Recovery remains possible if the rounding buffer or trading envelope is exhausted.
            _removePosition(true);
            token.resetEmptyCustody(token.indexRay());
        } else {
            _addPosition(initialShares * NET_FEE / FEE_DENOMINATOR, initialQuote * NET_FEE / FEE_DENOMINATOR);
        }
        token.commit();
        phase = IDLE;
        return "";
    }

    function previewTokens(bool buy, uint256 input) public view returns (Trade memory p) {
        if (!initialized || closed || phase != IDLE) revert InvalidPhase();
        (,, uint24 packedFee,) = poolManager.getSlot0(poolId);
        uint16 protocolFee = buy == (address(quoteToken) < address(token))
            ? ProtocolFeeLibrary.getZeroForOneFee(packedFee)
            : ProtocolFeeLibrary.getOneForZeroFee(packedFee);
        uint24 swapFee = ProtocolFeeLibrary.calculateSwapFee(protocolFee, FEE_PPM);
        p.buy = buy;
        p.input = input;
        if (input == 0 || input > InverseMath.MAX_DELTA) revert InvalidSwap();
        if (buy) {
            p.quote = input;
            (p.shares,) = InverseMath.amountOut(input, reserveQuote, reserveShares, swapFee);
        } else {
            p.shares = token.sharesForTokens(input);
            (p.quote,) = InverseMath.amountOut(p.shares, reserveShares, reserveQuote, swapFee);
        }
        // Reserve enough for core fee rounding and nominal-to-share rounding: at most one
        // reference input unit above the exact fee. Any unused fraction stays in custody.
        p.protocolInput = FullMath.mulDivRoundingUp(buy ? input : p.shares, protocolFee, FEE_DENOMINATOR);
        if (buy) p.protocolBefore = poolManager.protocolFeesAccrued(Currency.wrap(address(quoteToken)));
        p.nextShares = buy ? reserveShares - p.shares : reserveShares + p.shares - p.protocolInput;
        p.nextQuote = buy ? reserveQuote + p.quote - p.protocolInput : reserveQuote - p.quote;
        p.nextIndex = InverseMath.index(p.nextShares, p.nextQuote, initialShares, initialQuote);
        if (p.nextIndex < RAY || (buy ? p.nextIndex <= token.indexRay() : p.nextIndex >= token.indexRay())) {
            revert PriceDirection();
        }
        p.nativeInput = buy ? input - 1 : FullMath.mulDiv(p.shares, p.nextIndex, RAY);
        p.output = buy ? FullMath.mulDiv(p.shares, p.nextIndex, RAY) : p.quote;
        if (p.nativeInput == 0 || p.nativeInput >= input || p.output == 0 || p.output > InverseMath.MAX_DELTA)
        {
            revert InvalidSwap();
        }
        // A positive, hook-owned input claim makes omitted token settlement revert the unlock.
        p.inputClaim = input - p.nativeInput;
        // Core curve consumes (1 - swapFee) input; actual reserves retain (1 - protocolFee).
        // Their ratio sets the native position's capital fraction and preserves the endpoint.
        uint256 net = FEE_DENOMINATOR - swapFee;
        uint256 retained = FEE_DENOMINATOR - protocolFee;
        uint256 lp = swapFee - protocolFee;
        uint256 virtualShares = (reserveShares * net + (buy ? p.shares * lp : 0)) / retained;
        p.virtualInverse = FullMath.mulDiv(virtualShares, p.nextIndex, RAY);
        p.virtualQuote = (reserveQuote * net + (buy ? 0 : p.quote * lp)) / retained;
        if (p.virtualInverse > InverseMath.MAX_DELTA || p.virtualQuote > InverseMath.MAX_DELTA) {
            revert InvalidSwap();
        }
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        _canonical(key);
        if (
            params.amountSpecified >= 0 || params.amountSpecified == type(int256).min || data.length != 0
                || params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
                || params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
        ) {
            revert InvalidSwap();
        }
        bool buy = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1) == address(quoteToken);
        Trade memory p = previewTokens(buy, uint256(-params.amountSpecified));
        bool prepaid = prepaymentGuard;
        if (prepaid) {
            if (
                buy || token.prepaidNominal() != p.input || token.prepaidShares() != p.shares
                    || poolManager.currencyDelta(sender, Currency.wrap(address(token))) != int256(p.input)
            ) revert SettlementMismatch();
        }
        (previousSqrt,,,) = poolManager.getSlot0(poolId);
        _storePending(p);
        pendingRouter = sender;
        prepaidTrade = prepaid;
        phase = CORE_SWAP;
        if (prepaid) _releasePrepaymentGuard();
        token.beginLiquidity();
        _removePosition(false);
        token.resetEmptyCustody(p.nextIndex);
        _addPosition(p.virtualInverse, p.virtualQuote);
        // Core now executes a real native swap in the upcoming denomination.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(p.inputClaim)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        _canonical(key);
        if (phase != CORE_SWAP || sender != pendingRouter) revert InvalidPhase();
        Trade memory p = _loadPending();
        bool inverse0 = address(token) < address(quoteToken);
        int128 inputDelta = p.buy == inverse0 ? delta.amount1() : delta.amount0();
        int128 outDelta = p.buy == inverse0 ? delta.amount0() : delta.amount1();
        if (inputDelta != -int256(p.nativeInput) || outDelta <= 0) revert SettlementMismatch();
        uint256 out = uint128(outDelta);
        uint256 bound = p.buy
            ? FullMath.mulDivRoundingUp(32, p.virtualInverse, p.virtualQuote)
                + FullMath.mulDivRoundingUp(32, p.nextIndex, RAY) + 32
            : FullMath.mulDivRoundingUp(32, p.virtualQuote, p.virtualInverse) + 32;
        if (out > p.output ? out - p.output > bound : p.output - out > bound) revert RoundingLimit();
        outputCorrection = int128(int256(out) - int256(p.output));
        int128 correction = outputCorrection;
        if (p.buy) {
            uint256 fee =
                poolManager.protocolFeesAccrued(Currency.wrap(address(quoteToken))) - p.protocolBefore;
            if (fee > p.protocolInput) revert SettlementMismatch();
            nativeQuote += p.nativeInput - fee;
        } else {
            nativeQuote -= out;
        }
        _checkEndpoint(p);
        if (prepaidTrade) {
            _completePrepaid(p);
        } else {
            token.arm(p.buy, p.buy ? p.output : p.input, p.buy ? p.output : p.nativeInput, p.shares);
            phase = USER_SETTLEMENT;
        }
        return (IHooks.afterSwap.selector, correction);
    }

    /// @dev A positive credit cannot be removed by settleFor or another router. It forces the
    /// escrow to be consumed/refunded atomically; clearing/minting the payer's own credit cannot
    /// strand an old-denomination receipt or create persistent unbacked ERC-6909 inventory.
    function beginPrepayment() external {
        if (msg.sender != address(token)) revert Unauthorized();
        if (!initialized || closed || phase != IDLE || prepaymentGuard || !poolManager.isUnlocked()) {
            revert InvalidPhase();
        }
        _checkHookDeltas(0, 0);
        prepaymentGuard = true;
        _settleCurrency(Currency.wrap(address(quoteToken)), -1);
        poolManager.sync(Currency.wrap(address(token)));
    }

    function refundPrepayment() external {
        if (msg.sender != address(token)) revert Unauthorized();
        if (phase != IDLE || !prepaymentGuard) revert InvalidPhase();
        _releasePrepaymentGuard();
    }

    function _releasePrepaymentGuard() private {
        Currency quote = Currency.wrap(address(quoteToken));
        if (poolManager.currencyDelta(address(this), quote) != 1) revert SettlementMismatch();
        prepaymentGuard = false;
        poolManager.take(quote, address(this), 1);
    }

    function _completePrepaid(Trade memory p) private {
        phase = FINALIZING;
        Currency inverse = Currency.wrap(address(token));
        Currency quote = Currency.wrap(address(quoteToken));
        _checkHookDeltas(0, 0);
        if (poolManager.currencyDelta(pendingRouter, inverse) != int256(p.input)) {
            revert SettlementMismatch();
        }
        token.consumePrepayment(p.input, p.shares);
        // Hook deltas are accounted by PoolManager only AFTER afterSwap returns. Pre-settle
        // their opposites here. Taking this denomination difference leaves exactly nativeInput
        // in LP custody; it moves no ownership shares out of the reserve account.
        poolManager.take(inverse, address(this), p.inputClaim);
        _settleCurrency(quote, outputCorrection);
        _checkHookDeltas(-int256(p.inputClaim), -int256(outputCorrection));
        _commitTrade(p);
    }

    function inversePaid(address, uint256 receiptBefore) external {
        if (msg.sender != address(token) || phase != USER_SETTLEMENT) revert Unauthorized();
        Trade memory p = _loadPending();
        if (p.buy) revert Unauthorized();
        if (
            Currency.unwrap(poolManager.getSyncedCurrency()) != address(token)
                || poolManager.getSyncedReserves() != receiptBefore
                || poolManager.settleFor(pendingRouter) != p.input
        ) revert SettlementMismatch();
        _complete(p);
    }

    function inverseTaken(address) external {
        if (msg.sender != address(token) || phase != USER_SETTLEMENT) revert Unauthorized();
        Trade memory p = _loadPending();
        if (!p.buy) revert Unauthorized();
        _complete(p);
    }

    function _complete(Trade memory p) private {
        phase = FINALIZING;
        Currency inverse = Currency.wrap(address(token));
        Currency quote = Currency.wrap(address(quoteToken));
        Currency input = p.buy ? quote : inverse;
        Currency output = p.buy ? inverse : quote;
        if (
            poolManager.currencyDelta(address(this), input) != int256(p.inputClaim)
                || poolManager.currencyDelta(address(this), output) != outputCorrection
        ) revert SettlementMismatch();
        if (p.buy) poolManager.take(quote, address(this), 1);
        else poolManager.clear(inverse, p.inputClaim); // Retire the old/new denomination receipt, not assets.
        _settleCurrency(output, outputCorrection);
        _checkHookDeltas(0, 0);
        if (poolManager.currencyDelta(pendingRouter, inverse) != 0) revert SettlementMismatch();
        _commitTrade(p);
    }

    function _checkHookDeltas(int256 inverseDelta, int256 quoteDelta) private view {
        if (
            poolManager.currencyDelta(address(this), Currency.wrap(address(token))) != inverseDelta
                || poolManager.currencyDelta(address(this), Currency.wrap(address(quoteToken))) != quoteDelta
        ) revert SettlementMismatch();
    }

    function _commitTrade(Trade memory p) private {
        if (!p.buy && p.protocolInput != 0) token.collectProtocolFees(p.protocolInput);
        reserveShares = p.nextShares;
        reserveQuote = p.nextQuote;
        token.commit();
        if (
            token.custodiedShares() < reserveShares
                || quoteToken.balanceOf(address(this)) + nativeQuote < reserveQuote + roundingQuote
        ) {
            revert SettlementMismatch();
        }
        emit EconomicSwap(++sequence, pendingRouter, p.buy, p.shares, p.quote, p.nextIndex, tokenPriceRay());
        _clearPending();
        delete pendingRouter;
        delete outputCorrection;
        delete prepaidTrade;
        phase = IDLE;
    }

    function _removePosition(bool recovery) private {
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(poolKey(), _position(-int256(uint256(liquidity))), "");
        if (delta.amount0() < 0 || delta.amount1() < 0) revert SettlementMismatch();
        uint256 recovered = uint128(address(token) < address(quoteToken) ? delta.amount1() : delta.amount0());
        if (!recovery) {
            if (recovered > nativeQuote) revert SettlementMismatch();
            uint256 loss = nativeQuote - recovered;
            if (loss > MAX_CUSTODY_LOSS || loss > roundingQuote) revert RoundingLimit();
            roundingQuote -= loss;
            emit RoundingUsed(loss, roundingQuote);
        }
        _settleCurrency(poolKey().currency0, delta.amount0());
        _settleCurrency(poolKey().currency1, delta.amount1());
        liquidity = 0;
        nativeQuote = 0;
        if (poolManager.getLiquidity(poolId) != 0) revert SettlementMismatch();
    }

    function _addPosition(uint256 inverse, uint256 quote) private {
        if (inverse == 0 || quote == 0 || inverse > InverseMath.MAX_DELTA || quote > InverseMath.MAX_DELTA) {
            revert InvalidConfiguration();
        }
        uint160 target = _sqrt(inverse, quote);
        (uint160 current,,,) = poolManager.getSlot0(poolId);
        if (target != current) {
            BalanceDelta moved =
                poolManager.swap(poolKey(), IPoolManager.SwapParams(target < current, -1, target), "");
            if (BalanceDelta.unwrap(moved) != 0) revert SettlementMismatch();
        }
        // Both operands <= int128.max, so their product fits in uint256 and the root fits int128.
        liquidity = uint128(Math.sqrt(inverse * quote));
        if (liquidity == 0) revert InvalidConfiguration();
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(poolKey(), _position(int256(uint256(liquidity))), "");
        if (delta.amount0() >= 0 || delta.amount1() >= 0) revert SettlementMismatch();
        nativeQuote =
            uint256(-int256(address(token) < address(quoteToken) ? delta.amount1() : delta.amount0()));
        _settleCurrency(poolKey().currency0, delta.amount0());
        _settleCurrency(poolKey().currency1, delta.amount1());
    }

    function _settleCurrency(Currency currency, int128 delta) private {
        if (delta > 0) {
            poolManager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            if (poolManager.settle() != amount) revert SettlementMismatch();
        }
    }

    function _position(int256 amount) private pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams(
            TickMath.minUsableTick(60), TickMath.maxUsableTick(60), amount, bytes32(0)
        );
    }

    function _sqrt(uint256 inverse, uint256 quote) private view returns (uint160 result) {
        (uint256 numerator, uint256 denominator) =
            address(token) < address(quoteToken) ? (quote, inverse) : (inverse, quote);
        uint256 root = numerator / denominator < (uint256(1) << 64)
            ? Math.sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator))
            : Math.sqrt(FullMath.mulDiv(numerator, uint256(1) << 128, denominator)) << 32;
        if (
            root <= TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60))
                || root >= TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        ) revert InvalidConfiguration();
        result = uint160(root);
    }

    function _checkEndpoint(Trade memory p) private view {
        (uint160 current,,,) = poolManager.getSlot0(poolId);
        bool down = p.buy == (address(token) < address(quoteToken));
        if (down ? current >= previousSqrt : current <= previousSqrt) revert PriceDirection();
        uint256 expected = FullMath.mulDiv(FullMath.mulDiv(p.nextQuote, RAY, p.nextShares), RAY, p.nextIndex);
        uint256 actual = _price(current);
        uint256 tolerance = expected / 10_000_000 + 2; // Enforced endpoint error < 0.1 ppm plus 2 ray units.
        if (actual > expected ? actual - expected > tolerance : expected - actual > tolerance) {
            revert RoundingLimit();
        }
        if (poolManager.getLiquidity(poolId) == 0) revert SettlementMismatch();
    }

    function _price(uint160 sqrt) private view returns (uint256) {
        uint256 ratio = FullMath.mulDiv(sqrt, uint256(sqrt) * RAY, uint256(1) << 192);
        return address(token) < address(quoteToken) ? ratio : FullMath.mulDiv(RAY, RAY, ratio);
    }

    function tokenPriceRay() public view returns (uint256) {
        if (!initialized || closed) revert InvalidPhase();
        return FullMath.mulDiv(FullMath.mulDiv(reserveQuote, RAY, reserveShares), RAY, token.indexRay());
    }

    function nativePriceRay() external view returns (uint256) {
        if (!initialized || closed) revert InvalidPhase();
        (uint160 sqrt,,,) = poolManager.getSlot0(poolId);
        return _price(sqrt);
    }

    /// @dev Memory fields map one-to-one to namespaced EIP-1153 slots. Every field is overwritten
    /// before CORE_SWAP and cleared on commitment, so sequential swaps in one unlock are isolated.
    /// Reverts roll back transient writes just like ordinary storage writes.
    function _storePending(Trade memory trade) private {
        bytes32 slot = PENDING_TRADE_SLOT;
        assembly ("memory-safe") {
            for { let offset := 0 } lt(offset, TRADE_BYTES) { offset := add(offset, 32) } {
                tstore(add(slot, div(offset, 32)), mload(add(trade, offset)))
            }
        }
    }

    function _loadPending() private view returns (Trade memory trade) {
        bytes32 slot = PENDING_TRADE_SLOT;
        assembly ("memory-safe") {
            trade := mload(0x40)
            mstore(0x40, add(trade, TRADE_BYTES))
            for { let offset := 0 } lt(offset, TRADE_BYTES) { offset := add(offset, 32) } {
                mstore(add(trade, offset), tload(add(slot, div(offset, 32))))
            }
        }
    }

    function _clearPending() private {
        bytes32 slot = PENDING_TRADE_SLOT;
        assembly ("memory-safe") {
            for { let offset := 0 } lt(offset, TRADE_BYTES) { offset := add(offset, 32) } {
                tstore(add(slot, div(offset, 32)), 0)
            }
        }
    }

    function _canonical(PoolKey calldata key) private view {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert UnsupportedOperation();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert UnsupportedOperation();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert UnsupportedOperation();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert UnsupportedOperation();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnsupportedOperation();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnsupportedOperation();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnsupportedOperation();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnsupportedOperation();
    }
}
