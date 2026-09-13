// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {InverseHook} from "../../src/InverseHook.sol";
import {InverseToken} from "../../src/InverseToken.sol";
import {InverseGateway} from "../../src/InverseGateway.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {MockQuote} from "./MockQuote.sol";

abstract contract MarketFixture is Test {
    using TransientStateLibrary for IPoolManager;
    IPoolManager internal manager;
    MockQuote internal quote;
    InverseHook internal hook;
    InverseToken internal token;
    InverseGateway internal gateway;
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");
    uint256 internal constant SUPPLY = 1000e18;
    uint256 internal constant SEED = 1000e6;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        _deploy(6, 0, SUPPLY, SEED);
    }

    function _deploy(uint8 quoteDecimals, uint24 fee, uint256 shares, uint256 seed) internal {
        quote = _newQuote(quoteDecimals);
        bytes memory code = abi.encodePacked(
            vm.getCode("InverseHook.sol:InverseHook"),
            abi.encode(manager, quote, address(this), shares, seed, fee)
        );
        (bytes32 salt, address predicted) = HookMiner.find(address(this), keccak256(code), 0, 1_000_000);
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed == predicted && deployed.code.length > 0, "CREATE2 deployment failed");
        hook = InverseHook(deployed);
        token = hook.token();
        gateway = hook.gateway();
        quote.mint(address(this), seed);
        quote.approve(address(hook), seed);
        hook.initialize();
        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function _newQuote(uint8 decimals_) internal virtual returns (MockQuote) {
        return new MockQuote(decimals_);
    }

    function _fundAndApprove(address account) internal {
        quote.mint(account, 1e30);
        vm.startPrank(account);
        quote.approve(address(gateway), type(uint256).max);
        token.approveShares(address(gateway), type(uint256).max);
        vm.stopPrank();
    }

    function _buy(address account, uint256 amount) internal returns (uint256 shares) {
        vm.prank(account);
        (shares,,) = gateway.buy(amount, 0, account, block.timestamp);
    }

    function _sell(address account, uint256 shares) internal returns (uint256 amount) {
        vm.prank(account);
        (amount,) = gateway.sellShares(shares, 0, account, block.timestamp);
    }

    function _assertSettled() internal view {
        assertEq(token.sharesOf(address(manager)), 0);
        assertEq(token.sharesOf(address(gateway)), 0);
        assertEq(quote.balanceOf(address(gateway)), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(quote))), 0);
        assertEq(manager.currencyDelta(address(gateway), Currency.wrap(address(token))), 0);
        assertEq(manager.currencyDelta(address(gateway), Currency.wrap(address(quote))), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertFalse(token.settlementActive());
        assertEq(hook.phase(), 0);
        assertGe(token.sharesOf(address(hook)), hook.reserveShares());
        assertGe(quote.balanceOf(address(hook)), hook.reserveQuote());
    }
}
