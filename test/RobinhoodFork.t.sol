// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "./helpers/MarketFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev Read-only chain fork. Deployments, minting, and trades occur only in the local simulation.
contract RobinhoodForkTest is MarketFixture {
    bool private enabled;

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 pinnedBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pinnedBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinnedBlock);
        require(block.chainid == 4663, "wrong Robinhood chain");
        manager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        require(address(manager).code.length > 0, "PoolManager unavailable");
        enabled = true;
        _deploy(6, 3000, SUPPLY, SEED);
    }

    function testRobinhoodCanonicalManagerBuyBuySell() public {
        vm.skip(!enabled);
        uint256 first = _buy(alice, 100e6);
        uint256 price = hook.tokenPriceRay();
        _buy(bob, 100e6);
        assertLt(hook.tokenPriceRay(), price);
        uint256 proceeds = _sell(alice, first);
        assertGt(proceeds, 100e6);
        assertEq(token.sharesOf(alice), 0);
        _assertSettled();
    }
}
