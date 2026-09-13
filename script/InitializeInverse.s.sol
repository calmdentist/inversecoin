// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InverseHook} from "../src/InverseHook.sol";

/// @notice Irreversibly seeds the deployed market. Dry-run unless forge is passed --broadcast.
contract InitializeInverse is Script {
    using SafeERC20 for IERC20;

    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "unexpected chain");
        address deployer = vm.envAddress("DEPLOYER");
        InverseHook hook = InverseHook(vm.envAddress("INVERSE_HOOK"));
        require(hook.seeder() == deployer && !hook.initialized(), "wrong seeder or already initialized");
        require(address(hook.quoteToken()) == vm.envAddress("QUOTE_TOKEN"), "unexpected quote");
        require(hook.initialShares() == vm.envUint("INITIAL_SHARES"), "unexpected shares");
        require(hook.initialQuote() == vm.envUint("INITIAL_QUOTE"), "unexpected seed");
        console2.log("Permanently committing quote liquidity (raw)", hook.initialQuote());
        vm.startBroadcast(deployer);
        hook.quoteToken().forceApprove(address(hook), hook.initialQuote());
        hook.initialize();
        vm.stopBroadcast();
        console2.log("Initialized hook", address(hook));
    }
}
