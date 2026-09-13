// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "./helpers/MarketFixture.sol";
import {MockQuote} from "./helpers/MockQuote.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {InverseToken} from "../src/InverseToken.sol";
import {InverseGateway} from "../src/InverseGateway.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract AttackRouter is IUnlockCallback {
    IPoolManager private immutable manager;
    InverseHook private immutable hook;

    constructor(IPoolManager manager_, InverseHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attack(uint256 mode) external {
        manager.unlock(abi.encode(mode));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 mode = abi.decode(data, (uint256));
        PoolKey memory key = hook.poolKey();
        if (mode == 0 || mode == 6) {
            manager.swap(
                key,
                IPoolManager.SwapParams(
                    true, mode == 0 ? -int256(1e6) : int256(1e6), TickMath.MIN_SQRT_PRICE + 1
                ),
                ""
            );
        } else if (mode == 1 || mode == 2) {
            manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams(
                    -60, 60, mode == 1 ? int256(1e18) : -int256(1e18), bytes32(0)
                ),
                ""
            );
        } else if (mode == 3) {
            manager.donate(key, 1, 1, "");
        } else if (mode == 4) {
            hook.gateway().buy(1e6, 0, address(this), block.timestamp);
        } else {
            // Unfunded fixed-token claims must not survive unlock.
            manager.mint(address(this), uint256(uint160(address(hook.token()))), 1e18);
        }
        return "";
    }
}

contract AdversarialQuote is MockQuote {
    using TransientStateLibrary for IPoolManager;
    InverseHook public observedMarket;
    uint256 public expectedIndex;
    uint256 public mode;
    bool public sawFrozen;
    bool public sawUnlocked;
    bool public rejectedReentry;
    constructor(uint8 decimals_) MockQuote(decimals_) {}

    function configure(InverseHook market_, uint256 mode_) external {
        observedMarket = market_;
        expectedIndex = market_.token().indexRay();
        mode = mode_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (address(observedMarket) == address(0) || from == address(0) || to == address(0)) return;
        require(observedMarket.token().indexRay() == expectedIndex, "index changed during payment");
        require(observedMarket.token().settlementActive(), "index not frozen");
        sawFrozen = true;
        if (observedMarket.poolManager().isUnlocked()) sawUnlocked = true;
        if (mode == 1) _burn(to, 1); // fee-on-transfer
        if (mode == 2) {
            (bool ok,) = address(observedMarket.gateway())
                .call(abi.encodeCall(InverseGateway.buy, (1, 0, address(this), block.timestamp)));
            require(!ok, "reentry succeeded");
            rejectedReentry = true;
        }
        if (mode == 3) _burn(from, 1); // sender surcharge
    }
}

contract InverseSecurityTest is MarketFixture {
    function _newQuote(uint8 decimals_) internal override returns (MockQuote) {
        return new AdversarialQuote(decimals_);
    }

    function testBypassRoutersLiquidityDonationsNestedUnlockAndClaimsRejected() public {
        AttackRouter attacker = new AttackRouter(manager, hook);
        for (uint256 i; i < 7; ++i) {
            vm.expectRevert();
            attacker.attack(i);
            _assertSettled();
        }
    }

    function testCannotInitializeOtherPoolOrReinitialize() public {
        PoolKey memory key = hook.poolKey();
        key.fee = 100;
        vm.expectRevert();
        manager.initialize(key, uint160(1 << 96));
        vm.expectRevert(InverseHook.InvalidPhase.selector);
        hook.initialize();
    }

    function testCallbackAndRebaseCannotBeCalledByOutsiders() public {
        vm.expectRevert(InverseGateway.UnauthorizedCallback.selector);
        gateway.unlockCallback("");
        vm.expectRevert(InverseHook.Unauthorized.selector);
        hook.prepare(true, 1e6);
        vm.expectRevert(InverseHook.Unauthorized.selector);
        hook.finalize(alice, alice);
        vm.expectRevert(InverseToken.Unauthorized.selector);
        token.beginSettlement();
        vm.expectRevert(InverseToken.Unauthorized.selector);
        token.finishSettlement(2e27);
    }

    function testIndexFrozenThroughAllQuoteTransfersAndReentryRejected() public {
        AdversarialQuote adversary = AdversarialQuote(address(quote));
        adversary.configure(hook, 2);
        _buy(alice, 123_456789);
        assertTrue(adversary.sawFrozen());
        assertTrue(adversary.sawUnlocked());
        assertTrue(adversary.rejectedReentry());
        assertGt(token.indexRay(), adversary.expectedIndex());
        adversary.configure(hook, 2);
        _sell(alice, token.sharesOf(alice));
        assertLt(token.indexRay(), adversary.expectedIndex());
        _assertSettled();
    }

    function testTaxedQuoteBuyFullyReverts() public {
        AdversarialQuote(address(quote)).configure(hook, 1);
        uint256 balance = quote.balanceOf(alice);
        vm.expectRevert(InverseGateway.SettlementMismatch.selector);
        _buy(alice, 100e6);
        assertEq(quote.balanceOf(alice), balance);
        assertEq(hook.reserveQuote(), SEED);
        assertEq(token.indexRay(), 1e27);
        _assertSettled();
    }

    function testTaxedQuoteSellFullyReverts() public {
        _buy(alice, 100e6);
        AdversarialQuote(address(quote)).configure(hook, 1);
        uint256 shares = token.sharesOf(alice);
        uint256 index = token.indexRay();
        vm.expectRevert(); // Hook output settlement is rejected, wrapped by v4.
        _sell(alice, shares);
        assertEq(token.sharesOf(alice), shares);
        assertEq(token.indexRay(), index);
        _assertSettled();
    }

    function testSenderSurchargeCannotConsumeUnrelatedManagerQuote() public {
        // A quote that burns additional sender funds must fail even if PoolManager has inventory.
        quote.mint(address(manager), 1e6);
        AdversarialQuote(address(quote)).configure(hook, 3);
        uint256 beforeBalance = quote.balanceOf(alice);
        vm.expectRevert(InverseGateway.SettlementMismatch.selector);
        _buy(alice, 100e6);
        assertEq(quote.balanceOf(alice), beforeBalance);
        assertEq(quote.balanceOf(address(manager)), 1e6);
        _assertSettled();
    }

    function testUnrelatedManagerQuotePreserved() public {
        quote.mint(address(manager), 345e6);
        _buy(alice, 100e6);
        _sell(alice, token.sharesOf(alice));
        assertEq(quote.balanceOf(address(manager)), 345e6);
        _assertSettled();
    }
}
