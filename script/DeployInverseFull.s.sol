// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {InverseDeploymentBase} from "./InverseDeploymentBase.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Creates all contracts, approves quote, seeds liquidity and checks readiness in one run.
/// @dev Rerun identical configuration to recover partial broadcasts without creating a second market.
contract DeployInverseFull is InverseDeploymentBase {
    using SafeERC20 for IERC20;

    function run() external returns (InverseHook hook) {
        Config memory c = _config();
        bytes32 salt;
        address existing = vm.envOr("INVERSE_HOOK", address(0));
        if (existing == address(0)) {
            bytes32 initHash = keccak256(
                abi.encodePacked(
                    type(InverseHook).creationCode,
                    abi.encode(c.manager, c.quote, c.seeder, c.shares, c.seed, c.fee)
                )
            );
            (salt, existing) = HookMiner.findDeterministic(
                CREATE2_PROXY, initHash, vm.envOr("SALT_START", uint256(0)), 1_000_000
            );
        } else {
            require(existing.code.length > 0, "INVERSE_HOOK must be an existing deployment");
        }
        bool create = existing.code.length == 0;
        hook = InverseHook(existing);
        if (!create) _checkBindings(hook, c);
        bool initialize = create || !hook.initialized();

        // Check seed funding before queuing any deployment transaction.
        if (initialize) require(c.quote.balanceOf(c.seeder) >= c.seed, "insufficient quote for seed");
        if (create || initialize) require(c.seeder.balance > 0, "deployer needs native ETH for gas");
        console2.log("Chain", block.chainid);
        console2.log("Hook", existing);
        console2.log("Quote token", address(c.quote));
        console2.log("Quote decimals", uint256(c.quote.decimals()));
        console2.log("Seed quote, raw units; permanently locked", c.seed);
        console2.log("Reuse existing contracts", !create);
        console2.log("Already initialized", !initialize);

        if (create || initialize) {
            vm.startBroadcast(c.seeder);
            if (create) {
                hook = new InverseHook{salt: salt}(c.manager, c.quote, c.seeder, c.shares, c.seed, c.fee);
                require(address(hook) == existing, "CREATE2 proxy mismatch");
            }
            if (initialize) {
                if (c.quote.allowance(c.seeder, address(hook)) != c.seed) {
                    IERC20(address(c.quote)).forceApprove(address(hook), c.seed);
                }
                hook.initialize();
            }
            vm.stopBroadcast();
        }
        _checkReady(hook, c);
        console2.log("Token", address(hook.token()));
        console2.log("Gateway", address(hook.gateway()));
        console2.log("Simulation report", _report(hook, c, "simulated", create || initialize));
    }
}
