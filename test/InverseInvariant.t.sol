// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketFixture} from "./helpers/MarketFixture.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {InverseToken} from "../src/InverseToken.sol";
import {InverseGateway} from "../src/InverseGateway.sol";
import {MockQuote} from "./helpers/MockQuote.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract MarketHandler is Test {
    InverseHook public immutable market;
    InverseGateway private immutable gateway;
    InverseToken private immutable token;
    MockQuote private immutable quote;
    address[4] public actors;
    uint256 public referenceX = 1000e18;
    uint256 public referenceY = 1000e6;
    uint256 public buyCalls;
    uint256 public sellCalls;
    mapping(address => uint256) public referenceShares;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public received;

    constructor(InverseHook market_) {
        market = market_;
        gateway = market_.gateway();
        token = market_.token();
        quote = MockQuote(address(market_.quoteToken()));
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0x1000 + i));
            actors[i] = actor;
            quote.mint(actor, 1e24);
            vm.startPrank(actor);
            quote.approve(address(gateway), type(uint256).max);
            token.approveShares(address(gateway), type(uint256).max);
            vm.stopPrank();
        }
    }

    function buy(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 1e3, 1000e6);
        uint256 shares = _out(amount, referenceY, referenceX);
        uint256 oldPrice = market.tokenPriceRay();
        uint256 oldValue = market.spotValue(actors[(actorSeed % 4 + 1) % 4]);
        referenceX -= shares;
        referenceY += amount;
        referenceShares[actor] += shares;
        spent[actor] += amount;
        vm.prank(actor);
        (uint256 actual,,) = gateway.buy(amount, shares, actor, block.timestamp);
        assertEq(actual, shares);
        assertLt(market.tokenPriceRay(), oldPrice);
        assertGe(market.spotValue(actors[(actorSeed % 4 + 1) % 4]), oldValue);
        ++buyCalls;
    }

    function sell(uint256 actorSeed, uint256 fraction) external {
        address actor = actors[actorSeed % 4];
        uint256 held = referenceShares[actor];
        if (held == 0) return;
        uint256 shares = held * bound(fraction, 1, 100) / 100;
        uint256 amount = _out(shares, referenceX, referenceY);
        if (amount == 0) return; // Explicit unsupported sub-quote-unit dust, never swallow unexpected reverts.
        uint256 oldPrice = market.tokenPriceRay();
        referenceX += shares;
        referenceY -= amount;
        referenceShares[actor] -= shares;
        received[actor] += amount;
        vm.prank(actor);
        (uint256 actual,) = gateway.sellShares(shares, amount, actor, block.timestamp);
        assertEq(actual, amount);
        assertGt(market.tokenPriceRay(), oldPrice);
        ++sellCalls;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 fraction) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 shares = referenceShares[from] * bound(fraction, 0, 100) / 100;
        referenceShares[from] -= shares;
        referenceShares[to] += shares;
        vm.prank(from);
        token.transferShares(to, shares);
    }

    function _out(uint256 input, uint256 x, uint256 y) private view returns (uint256) {
        uint256 adjusted = input * (1_000_000 - market.feePpm());
        return adjusted * y / (x * 1_000_000 + adjusted);
    }
}

contract InverseInvariantTest is MarketFixture {
    MarketHandler internal handler;

    function setUp() public override {
        super.setUp();
        _deploy(6, 3000, SUPPLY, SEED);
        handler = new MarketHandler(hook);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = MarketHandler.buy.selector;
        selectors[1] = MarketHandler.sell.selector;
        selectors[2] = MarketHandler.transfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantShareConservationAndEconomicEquivalence() public view {
        uint256 total = token.sharesOf(address(hook));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 shares = token.sharesOf(actor);
            total += shares;
            assertEq(shares, handler.referenceShares(actor));
            assertEq(quote.balanceOf(actor), 1e24 + handler.received(actor) - handler.spent(actor));
            uint256 markedTokens = FullMath.mulDiv(token.balanceOf(actor), hook.tokenPriceRay(), 1e27);
            assertApproxEqAbs(markedTokens, hook.spotValue(actor), 2);
        }
        assertEq(total, SUPPLY);
        assertEq(hook.reserveShares(), handler.referenceX());
        assertEq(hook.reserveQuote(), handler.referenceY());
        assertGe(hook.reserveShares() * hook.reserveQuote(), SUPPLY * SEED);
    }

    function invariantAtomicSettlementAndDeterministicIndex() public view {
        _assertSettled();
        uint256 ratio = FullMath.mulDiv(hook.reserveQuote(), SUPPLY * 1e27, hook.reserveShares() * SEED);
        assertEq(token.indexRay(), FullMath.mulDiv(ratio, ratio, 1e27));
    }
}
