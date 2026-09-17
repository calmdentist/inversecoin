// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutedInverseTest} from "./RoutedInverse.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {RoutedInverseHook} from "../src/routed/RoutedInverseHook.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MockQuote} from "./helpers/MockQuote.sol";
import {RoutedInverseToken} from "../src/routed/RoutedInverseToken.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestProtocolController {
    struct CollectParams {
        Currency currency;
        uint256 amount;
    }
    IPoolManager public immutable POOL_MANAGER;
    address public immutable TOKEN_JAR;
    uint8 public mode;
    address public target;
    bool public reentered;
    mapping(address => uint256) public collected;

    function configure(uint8 mode_, address target_) external {
        mode = mode_;
        target = target_;
    }

    constructor(IPoolManager manager, address jar) {
        POOL_MANAGER = manager;
        TOKEN_JAR = jar;
    }

    function collect(CollectParams[] calldata params) external {
        if (mode == 1) return;
        if (mode == 2) revert("controller unavailable");
        if (mode == 5) {
            (reentered,) = target.call(abi.encodeCall(RoutedInverseHook.fundRounding, (1)));
            require(!reentered, "unexpected reentry");
        }
        if (mode == 7) {
            RoutedInverseHook h = RoutedInverseHook(target);
            PoolKey memory key = h.poolKey();
            bool direction = Currency.unwrap(key.currency0) == address(h.quoteToken());
            (reentered,) = address(POOL_MANAGER)
                .call(
                    abi.encodeCall(
                        IPoolManager.swap,
                        (
                            key,
                            IPoolManager.SwapParams(
                                direction,
                                -int256(1e12),
                                direction
                                    ? uint160(4306310045)
                                    : uint160(1456195216270955103206513029158776779468408838534)
                            ),
                            bytes("")
                        )
                    )
                );
            require(!reentered, "unexpected swap reentry");
        }
        for (uint256 i; i < params.length; ++i) {
            if (mode == 8) {
                POOL_MANAGER.take(params[i].currency, TOKEN_JAR, params[i].amount);
            } else {
                uint256 paid = POOL_MANAGER.collectProtocolFees(
                    mode == 6 ? target : TOKEN_JAR,
                    params[i].currency,
                    mode == 3 ? params[i].amount / 2 : params[i].amount
                );
                collected[Currency.unwrap(params[i].currency)] += paid;
                if (mode == 4) {
                    POOL_MANAGER.collectProtocolFees(TOKEN_JAR, params[i].currency, params[i].amount);
                }
            }
        }
    }
}

contract RoutedProtocolFeesTest is RoutedInverseTest {
    using TransientStateLibrary for IPoolManager;
    address internal jar = makeAddr("protocol fee recipient");
    TestProtocolController internal controller;

    function _fees(uint24 buyFee, uint24 sellFee) internal virtual {
        if (address(controller) == address(0)) {
            controller = new TestProtocolController(manager, jar);
            vm.prank(PoolManager(address(manager)).owner());
            manager.setProtocolFeeController(address(controller));
        }
        bool inverse0 = address(token) < address(quote);
        uint24 packed = inverse0 ? sellFee | (buyFee << 12) : buyFee | (sellFee << 12);
        PoolKey memory key = hook.poolKey();
        vm.prank(address(controller));
        manager.setProtocolFee(key, packed);
    }

    function testProtocolBuySellCollectionAndRecovery() public {
        _fees(1000, 1000);
        _feeTrade(alice, true, 1e14, 1000, 0);
        _feeTrade(bob, true, 2e14, 1000, 14);
        _feeTrade(alice, false, token.balanceOf(alice) / 2, 1000, 0);
        assertGt(token.sharesOf(jar), 0);
        uint256 held = token.sharesOf(jar);
        _feeTrade(bob, true, 1e14, 1000, 0);
        assertEq(token.sharesOf(jar), held);
        _feeTrade(alice, false, token.balanceOf(alice), 1000, 14);
        assertEq(token.sharesOf(alice), 0);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(token))), 0);
        assertGt(manager.protocolFeesAccrued(Currency.wrap(address(quote))), 0);
        hook.withdrawAll(address(this), hook.reserveQuote() + hook.roundingQuote() - 32, block.timestamp);
        assertTrue(hook.closed());
        assertEq(token.sharesOf(address(this)) + token.sharesOf(bob) + token.sharesOf(jar), X);
    }

    function testFuzzProtocolFeesAndSettlementOrders(
        uint16 buyRate,
        uint16 sellRate,
        uint64 a,
        uint64 b,
        uint16 fraction
    ) public {
        uint24 buyFee = uint24(bound(buyRate, 0, 1000));
        uint24 sellFee = uint24(bound(sellRate, 0, 1000));
        _fees(buyFee, sellFee);
        _feeTrade(alice, true, bound(a, 1e11, Y), buyFee, 0);
        _feeTrade(bob, true, bound(b, 1e11, Y), buyFee, 14);
        _feeTrade(alice, false, token.balanceOf(alice) * bound(fraction, 1, 9999) / 10000, sellFee, 1);
        _feeTrade(alice, false, token.balanceOf(alice), sellFee, 14);
        _feeTrade(bob, false, token.balanceOf(bob), sellFee, 0);
        assertEq(token.sharesOf(alice) + token.sharesOf(bob), 0);
    }

    function testFeeChangesAndQuoteCollectionsAcrossRebases() public {
        _fees(0, 1000);
        _feeTrade(alice, true, 1e14, 0, 0);
        _feeTrade(alice, false, token.balanceOf(alice) / 4, 1000, 14);
        uint256 held = token.sharesOf(jar);
        _fees(333, 0);
        _feeTrade(bob, true, 1e14, 333, 14);
        assertEq(token.sharesOf(jar), held);
        _collectQuote();
        _feeTrade(alice, false, token.balanceOf(alice), 0, 0);
        _fees(1000, 1);
        _feeTrade(alice, true, 3e14, 1000, 1);
        _feeTrade(bob, false, token.balanceOf(bob), 1, 1);
        _collectQuote();
        _fees(0, 0);
        _feeTrade(alice, false, token.balanceOf(alice), 0, 14);
    }

    function testZeroProtocolFeeDoesNotCallController() public {
        _fees(0, 0);
        _feeTrade(alice, true, 1e14, 0, 0);
        controller.configure(2, address(hook));
        _feeTrade(alice, false, token.balanceOf(alice), 0, 0);
        assertEq(token.sharesOf(jar), 0);
    }

    function testCollectionCannotReenterFundingOrSwap() public {
        _fees(1000, 1000);
        _feeTrade(alice, true, 1e14, 1000, 0);
        controller.configure(5, address(hook));
        _feeTrade(alice, false, token.balanceOf(alice) / 2, 1000, 14);
        assertFalse(controller.reentered());
        controller.configure(7, address(hook));
        _feeTrade(alice, false, token.balanceOf(alice), 1000, 0);
        assertFalse(controller.reentered());
    }

    function testRevertedPartialDuplicateAndForgedCollectionsRollback() public {
        _fees(1000, 1000);
        _feeTrade(alice, true, 1e14, 1000, 0);
        uint256 amount = token.balanceOf(alice);
        uint8[6] memory failures = [uint8(1), 2, 3, 4, 6, 8];
        for (uint256 i; i < failures.length; ++i) {
            controller.configure(failures[i], address(hook));
            bytes32 beforeState = _stateHash();
            vm.expectRevert();
            this.hostileSwap(false, amount, i % 2 == 0 ? 0 : 14);
            assertEq(_stateHash(), beforeState);
        }
        controller.configure(0, address(0));
        _feeTrade(alice, false, amount, 1000, 14);
    }

    function testControllerReplacementAndDisabledFeeRecovery() public {
        _fees(1000, 1000);
        _feeTrade(alice, true, 1e14, 1000, 0);
        manager.setProtocolFeeController(address(0));
        uint256 amount = token.balanceOf(alice);
        vm.expectRevert();
        this.hostileSwap(false, amount, 0);
        manager.setProtocolFeeController(address(controller));
        _fees(0, 0);
        _feeTrade(alice, false, amount, 0, 0);
    }

    function testFeeCollectionEntryRequiresMarketAndCorrectPhase() public {
        vm.expectRevert(RoutedInverseToken.Unauthorized.selector);
        token.collectProtocolFees(1);
        vm.prank(address(hook));
        vm.expectRevert(RoutedInverseToken.InvalidPhase.selector);
        token.collectProtocolFees(1);
    }

    function testProtocolRecipientCanSellRebasedFees() public {
        _fees(1000, 1000);
        _feeTrade(alice, true, 1e14, 1000, 0);
        _feeTrade(alice, false, token.balanceOf(alice), 1000, 0);
        uint256 shares = token.sharesOf(jar);
        uint256 amount = token.balanceOf(jar);
        uint256 beforeFees = controller.collected(address(token));
        Expected memory e = _expected(false, amount, 1000);
        uint256 beforeCash = quote.balanceOf(jar);
        _swap(jar, false, amount, e.output, 14);
        uint256 newFees = controller.collected(address(token)) - beforeFees;
        uint256 feeShares = (newFees * 1e27 + e.nextIndex - 1) / e.nextIndex;
        assertEq(token.sharesOf(jar), shares - e.shares + feeShares);
        assertEq(quote.balanceOf(jar), beforeCash + e.output);
        assertEq(hook.reserveShares(), e.nextX);
        assertEq(hook.reserveQuote(), e.nextY);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(token))), 0);
    }

    function testFeeEnabledArithmeticCeilingAndFullExit() public {
        _fees(1000, 1000);
        uint256 low = 1e14;
        uint256 high = 100 ether;
        while (high - low > 1) {
            uint256 middle = low + (high - low) / 2;
            try hook.previewTokens(true, middle) returns (RoutedInverseHook.Trade memory) {
                low = middle;
            } catch {
                high = middle;
            }
        }
        bytes32 beforeState = _stateHash();
        vm.expectRevert();
        this.hostileSwap(true, high, 0);
        assertEq(_stateHash(), beforeState);
        _feeTrade(alice, true, low, 1000, 0);
        assertLe(token.totalSupply(), uint256(uint128(type(int128).max)));
        _feeTrade(alice, false, token.balanceOf(alice), 1000, 14);
        assertEq(token.sharesOf(alice), 0);
        hook.withdrawAll(address(this), hook.reserveQuote() + hook.roundingQuote() - 32, block.timestamp);
        assertEq(token.sharesOf(address(this)) + token.sharesOf(jar), X);
    }

    function testPrepaidFeeCollectionRollsBackOnOutputSlippage() public {
        _fees(333, 777);
        _feeTrade(alice, true, 1e14, 333, 0);
        uint256 amount = token.balanceOf(alice);
        bytes32 beforeState = _stateHash();
        uint256 collected = controller.collected(address(token));
        vm.expectRevert();
        this.feeSlippage(amount);
        assertEq(_stateHash(), beforeState);
        assertEq(controller.collected(address(token)), collected);
        _feeTrade(alice, false, amount, 777, 14);
    }

    function feeSlippage(uint256 amount) external {
        _swap(alice, false, amount, hook.previewTokens(false, amount).output + 1, 14);
    }

    function _collectQuote() internal {
        uint256 beforeCash = quote.balanceOf(jar);
        uint256 amount = manager.protocolFeesAccrued(Currency.wrap(address(quote)));
        uint256 reserve = hook.reserveQuote();
        TestProtocolController.CollectParams[] memory params = new TestProtocolController.CollectParams[](1);
        params[0] = TestProtocolController.CollectParams(Currency.wrap(address(quote)), 0);
        vm.prank(bob);
        controller.collect(params);
        assertEq(quote.balanceOf(jar), beforeCash + amount);
        assertEq(hook.reserveQuote(), reserve);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(quote))), 0);
    }

    function _stateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.reserveShares(),
                hook.reserveQuote(),
                token.indexRay(),
                token.sharesOf(alice),
                token.custodiedShares(),
                token.balanceOf(address(manager)),
                quote.balanceOf(address(manager)),
                token.sharesOf(jar),
                hook.roundingQuote(),
                hook.phase(),
                token.phase(),
                manager.protocolFeesAccrued(Currency.wrap(address(token)))
            )
        );
    }

    struct Expected {
        uint256 shares;
        uint256 output;
        uint256 nextX;
        uint256 nextY;
        uint256 nextIndex;
    }

    function _expected(bool buy, uint256 amount, uint24 protocolFee)
        internal
        view
        returns (Expected memory e)
    {
        uint256 x = hook.reserveShares();
        uint256 y = hook.reserveQuote();
        e.shares = buy ? 0 : (amount * 1e27 + token.indexRay() - 1) / token.indexRay();
        uint256 referenceInput = buy ? amount : e.shares;
        uint256 totalFee = protocolFee + 3000 - uint256(protocolFee) * 3000 / 1e6;
        uint256 net = referenceInput * (1e6 - totalFee);
        e.output = net * (buy ? x : y) / ((buy ? y : x) * 1e6 + net);
        uint256 protocolCharge = (referenceInput * protocolFee + 1e6 - 1) / 1e6;
        e.nextX = buy ? x - e.output : x + e.shares - protocolCharge;
        e.nextY = buy ? y + amount - protocolCharge : y - e.output;
        uint256 relative = FullMath.mulDiv(e.nextY, X * 1e27, e.nextX * Y);
        e.nextIndex = FullMath.mulDiv(relative, relative, 1e27);
    }

    function _feeTrade(address who, bool buy, uint256 amount, uint24 protocolFee, uint8 mode) internal {
        Expected memory e = _expected(buy, amount, protocolFee);
        uint256 held = token.sharesOf(who);
        uint256 cash = quote.balanceOf(who);
        uint256 price = hook.nativePriceRay();
        RoutedInverseHook.Trade memory p = hook.previewTokens(buy, amount);
        assertEq(p.output, buy ? e.output * e.nextIndex / 1e27 : e.output);
        _swap(who, buy, amount, p.output, mode);
        assertEq(hook.reserveShares(), e.nextX);
        assertEq(hook.reserveQuote(), e.nextY);
        assertEq(token.indexRay(), e.nextIndex);
        assertEq(token.sharesOf(who), buy ? held + e.output : held - e.shares);
        assertEq(quote.balanceOf(who), buy ? cash - amount : cash + e.output);
        if (buy) assertLt(hook.nativePriceRay(), price);
        else assertGt(hook.nativePriceRay(), price);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(token))), 0);
        assertEq(
            token.sharesOf(alice) + token.sharesOf(bob) + token.sharesOf(jar) + token.custodiedShares(), X
        );
        assertGe(token.custodiedShares(), hook.reserveShares());
        assertGe(
            quote.balanceOf(address(hook)) + hook.nativeQuote(), hook.reserveQuote() + hook.roundingQuote()
        );
        assertEq(hook.phase(), 0);
        assertEq(token.phase(), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertApproxEqAbs(hook.nativePriceRay(), hook.tokenPriceRay(), hook.tokenPriceRay() / 10_000_000 + 2);
    }
}

contract RoutedProtocolFeesToken0Test is RoutedProtocolFeesTest {
    function _newQuote() internal override returns (MockQuote) {
        address target = address(type(uint160).max - 1);
        deployCodeTo("MockQuote.sol:MockQuote", abi.encode(uint8(18)), target);
        return MockQuote(target);
    }
}
