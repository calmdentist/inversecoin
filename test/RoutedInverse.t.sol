// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {RoutedInverseHook} from "../src/routed/RoutedInverseHook.sol";
import {RoutedInverseToken} from "../src/routed/RoutedInverseToken.sol";
import {MockQuote} from "./helpers/MockQuote.sol";
import {RouterCall, IUniversalInverseRouter, IInversePermit2} from "../script/RouterCall.sol";

contract RoutedTestRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    IPoolManager immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, bool direction, uint256 amount, uint256 minimum, uint8 mode) external {
        manager.unlock(abi.encode(key, direction, amount, minimum, mode, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool direction, uint256 amount, uint256 minimum, uint8 mode, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, uint256, uint8, address));
        Currency input = direction ? key.currency0 : key.currency1;
        Currency output = direction ? key.currency1 : key.currency0;
        if (mode >= 14 && mode != 20 && mode != 23 && mode != 24) {
            manager.sync(input);
            IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), amount);
            manager.settle();
            if (mode == 15) {
                manager.take(input, payer, amount);
                return "";
            }
            if (mode == 16) {
                manager.clear(input, amount);
                return "";
            }
            if (mode == 17) {
                manager.mint(payer, uint160(Currency.unwrap(input)), amount);
                return "";
            }
            if (mode == 21) {
                // A third party can add credit with settleFor; it cannot consume the hook's guard.
                manager.sync(output);
                IERC20(Currency.unwrap(output)).transfer(address(manager), 1);
                manager.settleFor(address(key.hooks));
                manager.clear(input, amount);
                return "";
            }
            if (mode == 18) amount -= 1;
        }
        if (mode == 12) manager.donate(key, 1, 1, "");
        if (mode == 13) {
            manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32(0)), "");
        }
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            direction,
            mode == 10 ? int256(amount) : -int256(amount),
            direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        if (mode == 9) {
            params.sqrtPriceLimitX96 = direction ? TickMath.MIN_SQRT_PRICE + 2 : TickMath.MAX_SQRT_PRICE - 2;
        }
        if (mode >= 14) {
            params.sqrtPriceLimitX96 =
                direction ? uint160(4306310045) : uint160(1456195216270955103206513029158776779468408838534);
        }
        if (mode == 19 || mode == 20) {
            RoutedInverseHook h = RoutedInverseHook(address(key.hooks));
            RoutedInverseHook.Trade memory p =
                h.previewTokens(Currency.unwrap(input) == address(h.quoteToken()), amount);
            bool inverse0 = address(h.token()) < address(h.quoteToken());
            uint256 numerator = inverse0 ? p.virtualQuote : p.virtualInverse;
            uint256 denominator = inverse0 ? p.virtualInverse : p.virtualQuote;
            uint160 start = uint160(Math.sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator)));
            params.sqrtPriceLimitX96 = direction ? start - 1 : start + 1;
        }
        BalanceDelta result = manager.swap(key, params, mode == 11 ? bytes(hex"01") : bytes(""));
        require(uint128(direction ? result.amount1() : result.amount0()) >= minimum, "minimum");
        if (mode == 23) {
            // Harmless ERC-20 probes must not consume either leg of an armed trade.
            IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), 0);
            IERC20(Currency.unwrap(output)).transferFrom(address(manager), payer, 0);
        }
        if (mode == 5) manager.swap(key, params, "");
        if (mode == 1) _take(output, payer);
        uint256 debt = uint256(-manager.currencyDelta(address(this), input));
        if (mode != 3 && debt != 0) {
            manager.sync(mode == 6 ? output : input);
            IERC20(Currency.unwrap(input))
                .transferFrom(payer, address(manager), mode == 7 ? debt - 1 : mode == 8 ? debt + 1 : debt);
            manager.settle();
        }
        if (mode == 2) {
            manager.mint(
                payer, uint160(Currency.unwrap(output)), uint256(manager.currencyDelta(address(this), output))
            );
        } else if (mode == 4) {
            manager.take(output, payer, uint256(manager.currencyDelta(address(this), output)) / 2);
        } else if (mode == 24) {
            manager.take(output, address(manager), uint256(manager.currencyDelta(address(this), output)));
        } else if (mode != 1) {
            _take(output, payer);
        }
        return "";
    }

    function _take(Currency currency, address payer) private {
        manager.take(currency, payer, uint256(manager.currencyDelta(address(this), currency)));
    }
}

contract RoutedInverseTest is Test {
    using stdStorage for StdStorage;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    IPoolManager internal manager;
    MockQuote internal quote;
    RoutedInverseHook internal hook;
    RoutedInverseToken internal token;
    RoutedTestRouter internal router;
    address internal alice = makeAddr("native Alice");
    address internal bob = makeAddr("native Bob");
    uint256 internal constant X = 100_000e18;
    uint256 internal constant Y = 0.003e18;
    bytes32 constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        _deploy();
    }

    function _deploy() internal {
        quote = _newQuote();
        address target = address(
            uint160(uint256(keccak256(abi.encode(manager, quote)))) & ~uint160(0x3fff) | uint160(0x2aec)
        );
        deployCodeTo(
            "RoutedInverseHook.sol:RoutedInverseHook", abi.encode(manager, quote, address(this), X, Y), target
        );
        hook = RoutedInverseHook(target);
        assertEq(uint160(target) & 0x3fff, hook.HOOK_FLAGS());
        token = hook.token();
        _fundQuote(address(this), Y + hook.ROUNDING_SEED());
        quote.approve(target, type(uint256).max);
        hook.initialize();
        _fundQuote(alice, 1e30);
        _fundQuote(bob, 1e30);
        router = new RoutedTestRouter(manager);
        _check();
    }

    function _newQuote() internal virtual returns (MockQuote) {
        return new MockQuote(18);
    }

    function _fundQuote(address actor, uint256 amount) internal virtual {
        quote.mint(actor, amount);
    }

    function _swap(address payer, bool buy, uint256 amount, uint256 minimum, uint8 mode) internal virtual {
        PoolKey memory key = hook.poolKey();
        address input = buy ? address(quote) : address(token);
        vm.startPrank(payer);
        IERC20(input).approve(address(router), mode == 8 ? amount + 1 : amount);
        router.swap(key, Currency.unwrap(key.currency0) == input, amount, minimum, mode);
        vm.stopPrank();
    }

    function _trade(address payer, bool buy, uint256 amount) internal {
        RoutedInverseHook.Trade memory p = hook.previewTokens(buy, amount);
        uint256 beforeShares = token.sharesOf(payer);
        uint256 beforeQuote = quote.balanceOf(payer);
        uint256 beforePrice = hook.nativePriceRay();
        vm.recordLogs();
        _swap(payer, buy, amount, p.output, 0);
        assertEq(token.sharesOf(payer), buy ? beforeShares + p.shares : beforeShares - p.shares);
        assertEq(quote.balanceOf(payer), buy ? beforeQuote - p.quote : beforeQuote + p.quote);
        assertEq(hook.reserveShares(), p.nextShares);
        assertEq(hook.reserveQuote(), p.nextQuote);
        assertEq(token.indexRay(), p.nextIndex);
        if (buy) assertLt(hook.nativePriceRay(), beforePrice);
        else assertGt(hook.nativePriceRay(), beforePrice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP) continue;
            (int128 a0, int128 a1,, uint128 l,, uint24 fee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            if (a0 == 0 && a1 == 0) continue;
            assertTrue(a0 != 0 && a1 != 0);
            assertGt(l, 0);
            assertEq(fee, _swapFee(buy));
            ++count;
        }
        assertEq(count, 1);
        _check();
    }

    function _check() internal view {
        assertEq(hook.phase(), 0);
        assertEq(token.phase(), 0);
        assertEq(token.prepaidNominal(), 0);
        assertEq(token.prepaidShares(), 0);
        assertFalse(hook.prepaymentGuard());
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertGe(token.custodiedShares(), hook.reserveShares());
        assertEq(_trackedExternalShares() + token.custodiedShares(), X);
        assertEq(token.sharesOf(address(manager)) + token.sharesOf(address(hook)), token.custodiedShares());
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(address(hook)),
            token.tokensForShares(token.custodiedShares())
        );
        assertEq(token.indexRay(), token.workingIndexRay());
        assertGe(
            quote.balanceOf(address(hook)) + hook.nativeQuote(), hook.reserveQuote() + hook.roundingQuote()
        );
        assertGt(manager.getLiquidity(hook.poolId()), 0);
        assertGt(token.balanceOf(address(manager)), 0);
        assertApproxEqAbs(hook.nativePriceRay(), hook.tokenPriceRay(), hook.tokenPriceRay() / 10_000_000 + 2);
    }

    function _trackedExternalShares() internal view virtual returns (uint256) {
        return token.sharesOf(alice) + token.sharesOf(bob);
    }

    function _swapFee(bool buy) internal view returns (uint24) {
        (,, uint24 packed,) = manager.getSlot0(hook.poolId());
        uint24 protocol = buy == (address(quote) < address(token)) ? packed & 0xfff : packed >> 12;
        return protocol + 3000 - protocol * 3000 / 1e6;
    }

    function testTwoBuysFullSaleAndFullRecovery() public {
        _trade(alice, true, 0.00003e18);
        uint256 shares = token.sharesOf(alice);
        uint256 valueBefore = FullMath.mulDiv(shares, hook.reserveQuote(), hook.reserveShares());
        _trade(bob, true, 0.00003e18);
        assertEq(token.sharesOf(alice), shares);
        assertGt(FullMath.mulDiv(shares, hook.reserveQuote(), hook.reserveShares()), valueBefore);
        _trade(alice, false, token.balanceOf(alice));
        assertEq(token.sharesOf(alice), 0);
        uint256 cash = hook.reserveQuote() + hook.roundingQuote();
        uint256 ownerBefore = quote.balanceOf(address(this));
        hook.withdrawAll(address(this), cash - 32, block.timestamp);
        assertGe(quote.balanceOf(address(this)) - ownerBefore, cash - 32);
        assertEq(token.sharesOf(address(this)) + token.sharesOf(bob), X);
        assertEq(manager.getLiquidity(hook.poolId()), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertTrue(hook.closed());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        vm.expectRevert();
        hook.previewTokens(true, 1e13);
    }

    function testFuzzEconomics(uint64 a, uint64 b, uint16 fraction) public {
        _trade(alice, true, bound(a, 1e10, Y));
        _trade(bob, true, bound(b, 1e10, Y));
        _trade(alice, false, token.balanceOf(alice) * bound(fraction, 1, 9999) / 10_000);
        _trade(alice, false, token.balanceOf(alice));
        _trade(bob, false, token.balanceOf(bob));
        assertEq(token.sharesOf(alice), 0);
        assertEq(token.sharesOf(bob), 0);
        assertGe(hook.reserveQuote(), Y);
    }

    function testTakeBeforePayWorksBothDirections() public {
        _swap(alice, true, 1e14, 0, 1);
        _check();
        _swap(alice, false, token.balanceOf(alice), 0, 1);
        _check();
    }

    function testPrepaidBuysPartialAndFullSells() public {
        _swap(alice, true, 1e14, 0, 14);
        _check();
        uint256 held = token.sharesOf(alice);
        uint256 oldValue = FullMath.mulDiv(held, hook.reserveQuote(), hook.reserveShares());
        _swap(bob, true, 1e14, 0, 14);
        assertEq(token.sharesOf(alice), held);
        assertGt(FullMath.mulDiv(held, hook.reserveQuote(), hook.reserveShares()), oldValue);
        uint256 amount = token.balanceOf(alice) / 2;
        RoutedInverseHook.Trade memory p = hook.previewTokens(false, amount);
        uint256 cashBefore = quote.balanceOf(alice);
        _swap(alice, false, amount, p.output, 14);
        assertEq(quote.balanceOf(alice) - cashBefore, p.output);
        assertEq(token.sharesOf(alice), held - p.shares);
        _check();
        _swap(alice, false, token.balanceOf(alice), 0, 14);
        _swap(bob, false, token.balanceOf(bob), 0, 14);
        assertEq(token.sharesOf(alice), 0);
        assertEq(token.sharesOf(bob), 0);
        _check();
    }

    function testPrepaymentCanBeRefundedAtomically() public {
        _trade(alice, true, 1e14);
        uint256 held = token.sharesOf(alice);
        uint256 beforeSequence = hook.sequence();
        _swap(alice, false, token.balanceOf(alice), 0, 15);
        assertEq(token.sharesOf(alice), held);
        assertEq(hook.sequence(), beforeSequence);
        assertEq(token.prepaidNominal(), 0);
        assertFalse(hook.prepaymentGuard());
        _check();
    }

    function testUnconsumedClearedAndClaimedPrepaymentsRevert() public {
        _trade(alice, true, 1e14);
        uint256 amount = token.balanceOf(alice);
        uint256 held = token.sharesOf(alice);
        _fundQuote(address(router), 1);
        for (uint8 mode = 16; mode <= 21; ++mode) {
            vm.expectRevert();
            this.hostileSwap(false, amount, mode);
            assertEq(token.sharesOf(alice), held);
            assertEq(token.prepaidNominal(), 0);
            assertFalse(hook.prepaymentGuard());
            _check();
        }
    }

    function testDistantNoncanonicalLimitsWorkBothDirections() public {
        _swap(alice, true, 1e14, 0, 9);
        _check();
        _swap(alice, false, token.balanceOf(alice), 0, 9);
        _check();
    }

    function testBindingBuyLimitsRevertWithAndWithoutPrepayment() public {
        for (uint8 mode = 19; mode <= 20; ++mode) {
            vm.expectRevert();
            this.hostileSwap(true, 1e14, mode);
            assertEq(token.sharesOf(alice), 0);
            assertEq(hook.reserveQuote(), Y);
            _check();
        }
    }

    function testUnclaimedRebaseRevertsEvenWith6909Output() public {
        uint256 beforeCash = quote.balanceOf(alice);
        vm.expectRevert();
        this.claimBuy();
        assertEq(quote.balanceOf(alice), beforeCash);
        assertEq(hook.reserveQuote(), Y);
        _check();
    }

    function claimBuy() external {
        _swap(alice, true, 1e14, 0, 2);
    }

    function testSlippageRevertsEverything() public {
        uint128 beforeL = manager.getLiquidity(hook.poolId());
        uint256 beforePrice = hook.nativePriceRay();
        vm.expectRevert();
        this.badMinimum();
        assertEq(manager.getLiquidity(hook.poolId()), beforeL);
        assertEq(hook.nativePriceRay(), beforePrice);
        assertEq(hook.reserveQuote(), Y);
        _check();
    }

    function badMinimum() external {
        _swap(alice, true, 1e14, type(uint128).max, 0);
    }

    function testHostileBuyPathsRollback() public {
        _fundQuote(address(manager), 1e18); // Unrelated v4 funds must not subsidize an unpaid buy.
        uint256 beforeCash = quote.balanceOf(alice);
        for (uint8 mode = 3; mode <= 13; ++mode) {
            if (mode == 9) continue; // Distant non-binding price limits are now supported.
            vm.expectRevert();
            this.hostileSwap(true, 1e14, mode);
            assertEq(quote.balanceOf(alice), beforeCash);
            assertEq(hook.reserveQuote(), Y);
            assertEq(token.sharesOf(alice), 0);
            _check();
        }
    }

    function hostileSwap(bool buy, uint256 amount, uint8 mode) external {
        // Exercise the abusive settlement router even in the Universal Router fork subclass.
        PoolKey memory key = hook.poolKey();
        address input = buy ? address(quote) : address(token);
        vm.startPrank(alice);
        IERC20(input).approve(address(router), type(uint256).max);
        router.swap(key, Currency.unwrap(key.currency0) == input, amount, 0, mode);
        vm.stopPrank();
    }

    function testHostileSellPathsRollback() public {
        _trade(alice, true, 1e14);
        uint256 held = token.sharesOf(alice);
        uint256 beforeCash = quote.balanceOf(alice);
        uint256 input = token.balanceOf(alice);
        // Partial quote takes and quote claims are valid only after the ownership input is paid.
        uint8[8] memory modes = [uint8(3), 5, 6, 7, 8, 10, 11, 13];
        for (uint256 i; i < modes.length; ++i) {
            vm.expectRevert();
            this.hostileSwap(false, input, modes[i]);
            assertEq(token.sharesOf(alice), held);
            assertEq(quote.balanceOf(alice), beforeCash);
            _check();
        }
    }

    function testUnauthorizedRecoveryRebaseAndBankAccessRevert() public {
        _trade(alice, true, 1e14);
        vm.startPrank(alice);
        vm.expectRevert();
        token.beginLiquidity();
        vm.expectRevert();
        token.resetEmptyCustody(1e30);
        vm.expectRevert();
        token.commit();
        vm.expectRevert();
        token.arm(true, 1, 1, 1);
        vm.expectRevert();
        token.consumePrepayment(1, 1);
        vm.expectRevert();
        token.transfer(address(manager), 1);
        vm.expectRevert();
        token.transferShares(address(manager), 1);
        vm.expectRevert();
        hook.inversePaid(alice, 0);
        vm.expectRevert();
        hook.inverseTaken(alice);
        vm.expectRevert();
        hook.beginPrepayment();
        vm.expectRevert();
        hook.refundPrepayment();
        vm.expectRevert();
        hook.withdrawAll(alice, 0, block.timestamp);
        vm.stopPrank();
        _check();
    }

    function testDonationDoesNotChangeCurveAndRecoveryIncludesDonation() public {
        _trade(alice, true, 1e14);
        uint256 price = hook.nativePriceRay();
        uint256 reserve = hook.reserveQuote();
        uint256 shares = hook.reserveShares();
        vm.startPrank(alice);
        token.transferShares(address(hook), 1234);
        quote.transfer(address(hook), 4567);
        vm.stopPrank();
        assertEq(hook.nativePriceRay(), price);
        assertEq(hook.reserveQuote(), reserve);
        assertEq(hook.reserveShares(), shares);
        _trade(bob, true, 1e14);
        assertEq(token.custodiedShares(), hook.reserveShares() + 1234);
        uint256 expected = hook.reserveQuote() + hook.roundingQuote() + 4567;
        (, uint256 recovered) = hook.withdrawAll(address(this), expected - 32, block.timestamp);
        assertGe(recovered, expected - 32);
    }

    function testArithmeticCeilingRevertsAtomicallyAndFullExitStillWorks() public {
        uint256 maximum = 19_293384144884426366;
        vm.expectRevert();
        hook.previewTokens(true, maximum + 1);
        _trade(alice, true, maximum);
        assertLe(token.totalSupply(), uint256(uint128(type(int128).max)));
        _trade(alice, false, token.balanceOf(alice));
        assertEq(token.sharesOf(alice), 0);
        hook.withdrawAll(address(this), hook.reserveQuote() + hook.roundingQuote() - 32, block.timestamp);
    }

    function testDustAndUintLimitsFailSafely() public {
        uint256[5] memory inputs =
            [uint256(0), 1, type(uint112).max, uint256(type(uint128).max), type(uint256).max];
        for (uint256 i; i < inputs.length; ++i) {
            vm.expectRevert();
            this.tryExtremeBuy(inputs[i]);
            _check();
        }
    }

    function tryExtremeBuy(uint256 input) external {
        _swap(alice, true, input, 0, 0);
    }

    function testProtocolFeesWithoutCollectionAdapterAllowBuysAndRecovery() public {
        _trade(alice, true, 1e14);
        vm.prank(PoolManager(address(manager)).owner());
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(hook.poolKey(), 100 | (100 << 12));
        uint256 beforeShares = token.sharesOf(alice);
        _swap(alice, true, 1e14, 0, 0);
        assertGt(token.sharesOf(alice), beforeShares);
        uint256 amount = token.balanceOf(alice);
        vm.expectRevert();
        this.hostileSwap(false, amount, 0);
        hook.withdrawAll(address(this), hook.reserveQuote() + hook.roundingQuote() - 32, block.timestamp);
        assertTrue(hook.closed());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function testZeroRoundingBufferStillAllowsFullRecovery() public {
        _trade(alice, true, 1e14);
        bytes32 slot = bytes32(stdstore.target(address(hook)).sig("roundingQuote()").find());
        vm.store(address(hook), slot, bytes32(0));
        vm.expectRevert();
        this.hostileSwap(true, 1e14, 0);
        hook.withdrawAll(address(this), hook.reserveQuote() - 32, block.timestamp);
        assertTrue(hook.closed());
        assertEq(token.sharesOf(address(this)) + token.sharesOf(alice), X);
    }
}

/// @dev Run the same settlement/security cases with INVERSE as currency0 as well.
contract RoutedInverseToken0Test is RoutedInverseTest {
    function _newQuote() internal override returns (MockQuote) {
        address target = address(type(uint160).max - 1);
        deployCodeTo("MockQuote.sol:MockQuote", abi.encode(uint8(18)), target);
        return MockQuote(target);
    }

    function setUp() public override {
        super.setUp();
        assertLt(uint160(address(token)), uint160(address(quote)));
    }
}

contract RoutedRobinhoodRouterTest is RoutedInverseTest {
    function setUp() public virtual override {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc, vm.envUint("ROBINHOOD_FORK_BLOCK"));
        manager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        _deploy();
    }

    function _swap(address payer, bool buy, uint256 amount, uint256 minimum, uint8 mode) internal override {
        if (mode != 0) {
            super._swap(payer, buy, amount, minimum, mode);
        } else {
            Currency input = Currency.wrap(buy ? address(quote) : address(token));
            (bytes memory commands, bytes[] memory inputs) =
                RouterCall.encode(hook.poolKey(), input, amount, minimum);
            vm.startPrank(payer);
            IERC20(Currency.unwrap(input)).approve(RouterCall.PERMIT2, amount);
            IInversePermit2(RouterCall.PERMIT2)
                .approve(
                    Currency.unwrap(input),
                    RouterCall.ROUTER,
                    uint160(amount),
                    uint48(block.timestamp + 1 hours)
                );
            IUniversalInverseRouter(RouterCall.ROUTER).execute(commands, inputs, block.timestamp + 15 minutes);
            vm.stopPrank();
        }
    }
}

interface IRoutedQuoter {
    struct Params {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(Params calldata) external returns (uint256, uint256);
}

contract RoutedRobinhoodWethTest is RoutedRobinhoodRouterTest {
    function _newQuote() internal pure override returns (MockQuote) {
        return MockQuote(RouterCall.WETH);
    }

    function _fundQuote(address actor, uint256 amount) internal override {
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        (bool ok,) = RouterCall.WETH.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(ok);
    }

    function testDeployedQuoterBuyAndFullSellAreExecutableAndReadOnly() public {
        _quotedTrade(true, 1e14);
        _quotedTrade(false, token.balanceOf(alice));
        assertEq(token.sharesOf(alice), 0);
    }

    function _quotedTrade(bool buy, uint256 input) private {
        uint256 shares = token.sharesOf(alice);
        uint256 quoteReserve = hook.reserveQuote();
        uint256 idx = token.indexRay();
        PoolKey memory key = hook.poolKey();
        (uint256 output,) = IRoutedQuoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94)
            .quoteExactInputSingle(
                IRoutedQuoter.Params(
                    key,
                    Currency.unwrap(key.currency0) == (buy ? address(quote) : address(token)),
                    uint128(input),
                    ""
                )
            );
        assertEq(output, hook.previewTokens(buy, input).output);
        assertEq(token.sharesOf(alice), shares);
        assertEq(hook.reserveQuote(), quoteReserve);
        assertEq(token.indexRay(), idx);
        _check();
        _trade(alice, buy, input);
    }
}

/// @dev Runs the deployed Kyber v4 adapter bytecode via a callback harness, using the
/// encoding decoded from the Fomo transaction in docs/FOMO_ROUTING_REVIEW.md. The signed
/// outer executor authenticates backend-generated quotes and is outside this adapter test.
contract RoutedKyberForkTest is RoutedRobinhoodWethTest {
    address private executor;

    function setUp() public override {
        super.setUp();
        executor = address(new KyberAdapterHarness(manager));
    }

    struct Hop {
        address output;
        uint24 fee;
        int24 spacing;
        address hooks;
        bytes hookData;
        uint256 limitAndFlags;
    }

    struct Leg {
        address input;
        uint256 amount;
        Hop[] hops;
    }

    function testActualKyberV4AdapterBuyPartialSellFullSell() public {
        _kyberTrade(alice, true, 1e14);
        _kyberTrade(bob, true, 1e14);
        _kyberTrade(alice, false, token.balanceOf(alice) / 2);
        _kyberTrade(alice, false, token.balanceOf(alice));
        assertEq(token.sharesOf(alice), 0);
        _kyberTrade(bob, false, token.balanceOf(bob));
        assertEq(token.sharesOf(bob), 0);
    }

    function testUniversalAndKyberCanTradeEachOthersPositions() public {
        _trade(alice, true, 1e14);
        uint256 aliceValue = token.sharesOf(alice) * hook.reserveQuote() / hook.reserveShares();
        _kyberTrade(bob, true, 1e14);
        assertGt(token.sharesOf(alice) * hook.reserveQuote() / hook.reserveShares(), aliceValue);
        _kyberTrade(alice, false, token.balanceOf(alice) / 2);
        _trade(bob, false, token.balanceOf(bob) / 2);
        _kyberTrade(alice, false, token.balanceOf(alice));
        _trade(bob, false, token.balanceOf(bob));
        assertEq(token.sharesOf(alice), 0);
        assertEq(token.sharesOf(bob), 0);
    }

    function testFuzzActualKyberV4Adapter(uint64 a, uint64 b, uint16 fraction) public {
        _kyberTrade(alice, true, bound(a, 1e11, Y));
        _kyberTrade(bob, true, bound(b, 1e11, Y));
        _kyberTrade(alice, false, token.balanceOf(alice) * bound(fraction, 1, 9999) / 10_000);
        _kyberTrade(alice, false, token.balanceOf(alice));
        _kyberTrade(bob, false, token.balanceOf(bob));
        assertEq(token.sharesOf(alice), 0);
        assertEq(token.sharesOf(bob), 0);
        assertGe(hook.reserveQuote(), Y);
    }

    function _kyberTrade(address payer, bool buy, uint256 amount) internal {
        address input = buy ? address(quote) : address(token);
        address output = buy ? address(token) : address(quote);
        RoutedInverseHook.Trade memory p = hook.previewTokens(buy, amount);
        uint256 held = token.sharesOf(payer);
        uint256 cash = quote.balanceOf(payer);
        uint256 price = hook.nativePriceRay();
        vm.prank(payer);
        IERC20(input).transfer(executor, amount);
        bytes memory data = _kyberData(input, output, amount);
        uint256 beforeOutput = IERC20(output).balanceOf(executor);
        KyberAdapterHarness(executor).execute(data);
        uint256 received = IERC20(output).balanceOf(executor) - beforeOutput;
        assertEq(received, p.output);
        vm.prank(executor);
        IERC20(output).transfer(payer, received);
        assertEq(token.sharesOf(payer), buy ? held + p.shares : held - p.shares);
        assertEq(quote.balanceOf(payer), buy ? cash - amount : cash + p.output);
        assertEq(hook.reserveShares(), p.nextShares);
        assertEq(hook.reserveQuote(), p.nextQuote);
        assertEq(token.indexRay(), p.nextIndex);
        if (buy) assertLt(hook.nativePriceRay(), price);
        else assertGt(hook.nativePriceRay(), price);
        assertEq(token.prepaidNominal(), 0);
        assertFalse(hook.prepaymentGuard());
        _check();
    }

    function _kyberData(address input, address output, uint256 amount) private view returns (bytes memory) {
        PoolKey memory key = hook.poolKey();
        Hop[] memory hops = new Hop[](1);
        uint160 limit =
            input < output ? uint160(4306310045) : uint160(1456195216270955103206513029158776779468408838534);
        hops[0] = Hop(output, key.fee, key.tickSpacing, address(hook), "", (uint256(5) << 160) | limit);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg(input, amount, hops);
        bytes memory route = abi.encode(address(manager), uint256(0x101), legs);
        return abi.encode(uint256(0x101), input, output, amount, executor, route);
    }
}

contract KyberAdapterHarness is IUnlockCallback {
    IPoolManager private immutable manager;
    address private constant ADAPTER = 0x7B0E2E8300899b647d5ebc66f9d4fa3f16C54061;

    constructor(IPoolManager manager_) {
        manager = manager_;
        require(ADAPTER.code.length != 0, "missing live Kyber adapter");
    }

    function execute(bytes calldata data) external {
        manager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool ok, bytes memory result) = ADAPTER.delegatecall(abi.encodeCall(this.unlockCallback, (data)));
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return abi.decode(result, (bytes));
    }
}

/// @dev Independent integer CP ledger. Never reads the market preview or production math library.
contract RoutedLedgerHandler is Test {
    RoutedInverseHook immutable hook;
    RoutedInverseToken immutable token;
    IERC20 immutable quote;
    RoutedTestRouter immutable router;
    address[2] public actors;
    mapping(address => uint256) public held;
    mapping(address => uint256) public cash;
    uint256 public x = 100_000e18;
    uint256 public y = 0.003e18;
    uint256 public r = 1e27;
    uint256 public trades;

    constructor(RoutedInverseHook h, RoutedTestRouter rt, address alice, address bob) {
        hook = h;
        token = h.token();
        quote = h.quoteToken();
        router = rt;
        actors = [alice, bob];
        cash[alice] = quote.balanceOf(alice);
        cash[bob] = quote.balanceOf(bob);
    }

    function buy(uint256 actor, uint256 fraction) external {
        address payer = actors[actor % 2];
        uint256 input = y * bound(fraction, 1, 10) / 100;
        uint256 output = _out(input, y, x);
        x -= output;
        y += input;
        held[payer] += output;
        cash[payer] -= input;
        _index();
        _swap(payer, true, input, FullMath.mulDiv(output, r, 1e27));
    }

    function sell(uint256 actor, uint256 fraction) external {
        address payer = actors[actor % 2];
        if (held[payer] == 0) return;
        uint256 nominal = held[payer] * r / 1e27 * bound(fraction, 1, 100) / 100;
        uint256 shares = (nominal * 1e27 + r - 1) / r;
        uint256 output = _out(shares, x, y);
        if (nominal == 0 || output < 1000) return;
        x += shares;
        y -= output;
        held[payer] -= shares;
        cash[payer] += output;
        _index();
        _swap(payer, false, nominal, output);
    }

    function transfer(uint256 actor, uint256 fraction) external {
        address from = actors[actor % 2];
        address to = actors[(actor % 2 + 1) % 2];
        uint256 shares = held[from] * bound(fraction, 0, 100) / 100;
        held[from] -= shares;
        held[to] += shares;
        vm.prank(from);
        token.transferShares(to, shares);
    }

    function _swap(address payer, bool buy_, uint256 input, uint256 minimum) private {
        PoolKey memory key = hook.poolKey();
        address currency = buy_ ? address(quote) : address(token);
        vm.startPrank(payer);
        IERC20(currency).approve(address(router), input);
        router.swap(
            key,
            Currency.unwrap(key.currency0) == currency,
            input,
            minimum,
            uint8(trades++ % 3 == 2 ? 14 : trades % 2)
        );
        vm.stopPrank();
    }

    function _index() private {
        uint256 relative = y * 100_000e18 * 1e27 / (x * 0.003e18);
        r = relative * relative / 1e27;
    }

    function _out(uint256 input, uint256 a, uint256 b) private pure returns (uint256) {
        uint256 adjusted = input * 997_000;
        return adjusted * b / (a * 1_000_000 + adjusted);
    }
}

contract RoutedInverseInvariantTest is RoutedInverseTest {
    RoutedLedgerHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new RoutedLedgerHandler(hook, router, alice, bob);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RoutedLedgerHandler.buy.selector;
        selectors[1] = RoutedLedgerHandler.sell.selector;
        selectors[2] = RoutedLedgerHandler.transfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantOrdinaryMarketSharesAndCashMatchExactly() public view {
        assertEq(hook.reserveShares(), handler.x());
        assertEq(hook.reserveQuote(), handler.y());
        assertEq(token.indexRay(), handler.r());
        for (uint256 i; i < 2; ++i) {
            address actor = handler.actors(i);
            assertEq(token.sharesOf(actor), handler.held(actor));
            assertEq(quote.balanceOf(actor), handler.cash(actor));
        }
    }

    function invariantCustodyConservedAndSettlementClosed() public view {
        _check();
        assertEq(token.custodiedShares(), hook.reserveShares());
        assertEq(
            quote.balanceOf(address(hook)) + hook.nativeQuote(), hook.reserveQuote() + hook.roundingQuote()
        );
        assertGe(token.indexRay(), 1e27);
    }
}
