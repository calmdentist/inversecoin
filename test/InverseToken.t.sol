// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "./helpers/MarketFixture.sol";
import {InverseToken} from "../src/InverseToken.sol";
import {InverseMath} from "../src/libraries/InverseMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract InverseTokenTest is MarketFixture {
    function testFuzzShareTransfersConserveOwnership(uint96 input, uint96 fraction) public {
        _buy(alice, bound(input, 1e6, 10_000e6));
        uint256 held = token.sharesOf(alice);
        uint256 shares = bound(fraction, 0, held);
        vm.prank(alice);
        token.transferShares(bob, shares);
        assertEq(token.sharesOf(alice), held - shares);
        assertEq(token.sharesOf(bob), shares);
        _buy(bob, 100e6);
        assertEq(token.sharesOf(alice), held - shares);
        assertEq(token.sharesOf(alice) + token.sharesOf(bob) + token.sharesOf(address(hook)), SUPPLY);
        assertEq(token.totalSupply(), FullMath.mulDiv(SUPPLY, token.indexRay(), 1e27));
        _assertSettled();
    }

    function testTokenAllowanceRemainsNominalAndShareAllowanceRemainsShares() public {
        _buy(alice, 100e6);
        vm.startPrank(alice);
        token.approve(bob, 10e18);
        token.approveShares(bob, 11e18);
        vm.stopPrank();
        _buy(bob, 100e6);
        uint256 fromShares = token.sharesOf(alice);
        uint256 transferredShares = token.sharesForTokens(10e18);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10e18);
        assertEq(token.sharesOf(alice), fromShares - transferredShares);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.shareAllowance(alice, bob), 11e18);
        vm.prank(bob);
        token.transferSharesFrom(alice, bob, 11e18);
        assertEq(token.shareAllowance(alice, bob), 0);
        assertEq(token.sharesOf(alice), fromShares - transferredShares - 11e18);
    }

    function testSubShareTransfersRejectAndZeroTransfersWork() public {
        _buy(alice, 100e6);
        vm.startPrank(alice);
        token.transfer(bob, 0);
        vm.expectRevert(InverseToken.UnrepresentableAmount.selector);
        token.transfer(bob, 1);
        vm.expectRevert(InverseToken.InvalidAddress.selector);
        token.transferShares(address(0), 1);
        vm.stopPrank();
    }

    function testSellTokensThenSellAllClearsRoundingRemainder() public {
        _buy(alice, 100e6);
        _buy(bob, 100e6);
        uint256 amount = token.balanceOf(alice) / 2;
        uint256 expectedShares = token.sharesForTokens(amount);
        vm.startPrank(alice);
        (, uint256 sold) = gateway.sellTokens(amount, 0, alice, block.timestamp);
        assertEq(sold, expectedShares);
        gateway.sellAll(0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(token.sharesOf(alice), 0);
        _assertSettled();
    }

    function testWholeSupplyDeltaBoundPreservesLargeFullExit() public {
        _deploy(6, 0, 1e30, 1e15);
        _buy(alice, 1e17);
        assertLe(token.totalSupply(), uint256(uint128(type(int128).max)));
        vm.expectRevert(InverseMath.IndexBounds.selector);
        _buy(bob, 1e17);
        _sell(alice, token.sharesOf(alice));
        assertEq(token.sharesOf(alice), 0);
        _assertSettled();
    }

    function testRepeatedTinyRoundTripsCannotExtractReserves() public {
        uint256 beforeBalance = quote.balanceOf(alice);
        for (uint256 i; i < 32; ++i) {
            uint256 shares = _buy(alice, 2 + i);
            _sell(alice, shares);
        }
        assertLe(quote.balanceOf(alice), beforeBalance);
        assertGe(hook.reserveQuote(), SEED);
        assertEq(token.sharesOf(alice), 0);
        _assertSettled();
    }
}
