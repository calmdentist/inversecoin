// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "./helpers/MarketFixture.sol";
import {IInverseMarket} from "../src/interfaces/IInverseMarket.sol";
import {InverseGateway} from "../src/InverseGateway.sol";
import {InverseToken} from "../src/InverseToken.sol";
import {InverseMath} from "../src/libraries/InverseMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract InverseMarketTest is MarketFixture {
    function testWhitepaperAliceBobFullExit() public {
        assertEq(hook.sharePriceRay(), 1e27);
        assertEq(hook.tokenPriceRay(), 1e27);
        uint256 aliceStart = quote.balanceOf(alice);
        uint256 aliceShares = _buy(alice, 100e6);
        assertApproxEqAbs(aliceShares, uint256(1000e18) / 11, 1);
        assertApproxEqAbs(hook.sharePriceRay(), 121e25, 1e8);
        assertApproxEqAbs(token.balanceOf(alice), 1331e17, 10);
        uint256 aliceValue = hook.spotValue(alice);
        uint256 firstPrice = hook.tokenPriceRay();
        _buy(bob, 100e6);
        assertLt(hook.tokenPriceRay(), firstPrice);
        assertGt(hook.spotValue(alice), aliceValue);
        assertEq(token.sharesOf(alice), aliceShares);
        assertApproxEqAbs(hook.sharePriceRay(), 144e25, 1e8);
        assertApproxEqAbs(token.balanceOf(alice), 188_509090909090909090, 20);
        uint256 secondPrice = hook.tokenPriceRay();
        vm.prank(alice);
        (uint256 proceeds, uint256 sold) = gateway.sellAll(118e6, alice, block.timestamp);
        assertEq(sold, aliceShares);
        assertEq(proceeds, 118_032786); // Floor rounding is within one raw USDC unit of 7200/61.
        assertEq(token.sharesOf(alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(quote.balanceOf(alice) - aliceStart, 18_032786);
        assertGt(hook.tokenPriceRay(), secondPrice);
        _assertSettled();
    }

    function testFuzzDifferentialBuysAndPartialSells(uint96 a, uint96 b, uint96 part, uint24 fee) public {
        fee = uint24(bound(fee, 0, 100_000));
        // Immutable fees vary by market; deploy with genuine CREATE2 permissions.
        _deploy(6, fee, SUPPLY, SEED);
        uint256 inputA = bound(a, 10_000, 1_000_000e6);
        uint256 inputB = bound(b, 10_000, 1_000_000e6);
        uint256 x = SUPPLY;
        uint256 y = SEED;
        uint256 ordinaryA = _ordinaryOut(inputA, y, x, fee);
        assertEq(_buy(alice, inputA), ordinaryA);
        x -= ordinaryA;
        y += inputA;
        uint256 ordinaryB = _ordinaryOut(inputB, y, x, fee);
        assertEq(_buy(bob, inputB), ordinaryB);
        x -= ordinaryB;
        y += inputB;
        uint256 sold = bound(part, ordinaryA / 100 + 1, ordinaryA);
        uint256 ordinaryQuote = _ordinaryOut(sold, x, y, fee);
        assertEq(_sell(alice, sold), ordinaryQuote);
        assertEq(hook.reserveShares(), x + sold);
        assertEq(hook.reserveQuote(), y - ordinaryQuote);
        assertEq(token.sharesOf(alice) + token.sharesOf(bob) + token.sharesOf(address(hook)), SUPPLY);
        assertGe(hook.reserveShares() * hook.reserveQuote(), SUPPLY * SEED);
        _assertSettled();
    }

    function _ordinaryOut(uint256 amount, uint256 x, uint256 y, uint24 fee) private pure returns (uint256) {
        // Independent reference formula. Test bounds keep this direct product within uint256.
        uint256 withFee = amount * (1_000_000 - fee);
        return withFee * y / (x * 1_000_000 + withFee);
    }

    function testFuzzRoundTripCannotCreateQuote(uint80 raw) public {
        uint256 amount = bound(raw, 1, 1_000_000e6);
        uint256 shares = _buy(alice, amount);
        if (amount == 1) {
            // A sub-quote-unit exit has zero representable output and reverts atomically.
            vm.expectRevert(InverseMath.InvalidAmount.selector);
            _sell(alice, shares);
        } else {
            uint256 out = _sell(alice, shares);
            assertLe(out, amount);
            assertLe(amount - out, 1);
        }
        _assertSettled();
    }

    function testFeesAreRetainedAndBothDirectionsInvert() public {
        _deploy(6, 3000, SUPPLY, SEED);
        uint256 shares = _buy(alice, 100e6);
        uint256 buyPrice = hook.tokenPriceRay();
        uint256 out = _sell(alice, shares);
        assertLt(out, 100e6);
        assertGt(hook.tokenPriceRay(), buyPrice);
        assertGt(hook.reserveQuote(), SEED);
        assertEq(hook.reserveShares(), SUPPLY);
        _assertSettled();
    }

    function testDecimalNormalization18() public {
        _deploy(18, 0, SUPPLY, 1000e18);
        _buy(alice, 100e18);
        assertApproxEqAbs(hook.sharePriceRay(), 121e25, 1e8);
        assertApproxEqAbs(token.balanceOf(alice), 1331e17, 10);
        _assertSettled();
    }

    function testSlippageDeadlineAndAllowanceRollback() public {
        vm.startPrank(alice);
        vm.expectRevert(InverseGateway.Slippage.selector);
        gateway.buy(100e6, 100e18, alice, block.timestamp);
        vm.expectRevert(InverseGateway.Expired.selector);
        gateway.buy(100e6, 0, alice, block.timestamp - 1);
        vm.stopPrank();
        assertEq(hook.reserveShares(), SUPPLY);
        assertEq(token.indexRay(), 1e27);
        _buy(alice, 100e6);
        uint256 shares = token.sharesOf(alice);
        vm.startPrank(alice);
        token.approveShares(address(gateway), 0);
        vm.expectRevert(InverseToken.InsufficientAllowance.selector);
        gateway.sellShares(shares, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(token.sharesOf(alice), shares);
        _assertSettled();
    }

    function testDonationsDoNotChangeAccountedPrice() public {
        _buy(alice, 100e6);
        uint256 price = hook.tokenPriceRay();
        uint256 index = token.indexRay();
        vm.startPrank(alice);
        token.transferShares(address(hook), 1e18);
        quote.transfer(address(hook), 7e6);
        vm.stopPrank();
        assertEq(hook.tokenPriceRay(), price);
        assertEq(token.indexRay(), index);
        (uint256 extraShares, uint256 extraQuote) = hook.surplus();
        assertEq(extraShares, 1e18);
        assertEq(extraQuote, 7e6);
        _buy(bob, 100e6);
        (extraShares, extraQuote) = hook.surplus();
        assertEq(extraShares, 1e18);
        assertEq(extraQuote, 7e6);
        _assertSettled();
    }

    function testManagerDonationsRejectedAndFullExitHasNoShareDust() public {
        _buy(alice, 123_456789);
        _buy(bob, 57_923421);
        vm.startPrank(alice);
        vm.expectRevert(InverseToken.InvalidSettlement.selector);
        token.transferShares(address(manager), 1);
        gateway.sellAll(0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(token.sharesOf(alice), 0);
        _assertSettled();
    }

    function testBoundsRejectBuyAndAllowFullExit() public {
        _buy(alice, 10_000_000e6);
        vm.expectRevert(InverseMath.IndexBounds.selector);
        _buy(bob, 1e16);
        uint256 beforePrice = hook.tokenPriceRay();
        _sell(alice, token.sharesOf(alice));
        assertGt(hook.tokenPriceRay(), beforePrice);
        assertEq(token.sharesOf(alice), 0);
        _assertSettled();
    }

    function testNativePriceDoesNotPretendToBeInversePrice() public {
        (uint160 nativeBefore,,,) = StateLibrary.getSlot0(manager, hook.poolId());
        IInverseMarket.Trade memory first = hook.preview(true, 1e6);
        _buy(alice, 1e6);
        uint256 firstPrice = hook.tokenPriceRay();
        IInverseMarket.Trade memory second = hook.preview(true, 1000e6);
        _buy(bob, 1000e6);
        (uint160 nativeAfter,,,) = StateLibrary.getSlot0(manager, hook.poolId());
        assertEq(nativeBefore, nativeAfter);
        assertLt(hook.tokenPriceRay(), firstPrice);
        // Proves why execution-ratio candles cannot establish the target chart behavior.
        assertGt(
            FullMath.mulDiv(second.quote, 1e27, second.settlementTokens),
            FullMath.mulDiv(first.quote, 1e27, first.settlementTokens)
        );
    }
}
