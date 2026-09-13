// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {InverseGateway} from "../src/InverseGateway.sol";
import {HookMiner} from "./HookMiner.sol";
import {MockQuote} from "../test/helpers/MockQuote.sol";

/// @dev Simulates the whitepaper example locally. No RPC, wallet, or funds required.
contract LocalDemo is Script {
    function run() external {
        address seeder = address(0x5EED);
        DemoFactory factory = new DemoFactory();
        IPoolManager manager = IPoolManager(address(new PoolManager(seeder)));
        MockQuote quote = new MockQuote(6);
        bytes memory code = abi.encodePacked(
            type(InverseHook).creationCode, abi.encode(manager, quote, seeder, 1000e18, 1000e6, uint24(0))
        );
        (bytes32 salt,) = HookMiner.find(address(factory), keccak256(code), 0, 1_000_000);
        InverseHook hook = InverseHook(factory.deploy(code, salt));
        quote.mint(seeder, 1000e6);
        vm.startPrank(seeder);
        quote.approve(address(hook), 1000e6);
        hook.initialize();
        vm.stopPrank();
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        InverseGateway gateway = hook.gateway();
        quote.mint(alice, 100e6);
        quote.mint(bob, 100e6);
        vm.startPrank(alice);
        quote.approve(address(gateway), 100e6);
        gateway.buy(100e6, 0, alice, block.timestamp);
        hook.token().approveShares(address(gateway), type(uint256).max);
        vm.stopPrank();
        console2.log("After Alice buy: inverse price (ray)", hook.tokenPriceRay());
        vm.startPrank(bob);
        quote.approve(address(gateway), 100e6);
        gateway.buy(100e6, 0, bob, block.timestamp);
        vm.stopPrank();
        console2.log("After Bob buy: inverse price (ray)", hook.tokenPriceRay());
        console2.log("Alice displayed balance (18 decimals)", hook.token().balanceOf(alice));
        vm.prank(alice);
        (uint256 out,) = gateway.sellAll(118e6, alice, block.timestamp);
        console2.log("Alice exit quote (6 decimals)", out);
        console2.log("After Alice sell: inverse price (ray)", hook.tokenPriceRay());
    }
}

/// @dev Local simulation helper; not part of the deployed protocol.
contract DemoFactory {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0), "demo deployment failed");
    }
}
