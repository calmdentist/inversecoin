// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Deploys contracts only. Seed liquidity separately with InitializeInverse.
contract DeployInverse is Script {
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant ROBINHOOD_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external returns (InverseHook hook) {
        uint256 expectedChain = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expectedChain, "unexpected chain");
        require(
            expectedChain == 4663 || expectedChain == 46630 || expectedChain == 31337, "unsupported chain"
        );
        address manager = vm.envOr("POOL_MANAGER", expectedChain == 4663 ? ROBINHOOD_MANAGER : address(0));
        require(manager.code.length > 0, "set a deployed PoolManager");
        address quote = vm.envAddress("QUOTE_TOKEN");
        address deployer = vm.envAddress("DEPLOYER");
        uint256 shares = vm.envUint("INITIAL_SHARES");
        uint256 seed = vm.envUint("INITIAL_QUOTE");
        uint256 fee = vm.envOr("FEE_PPM", uint256(3000));
        require(fee < 1_000_000, "invalid fee");
        bytes memory args = abi.encode(manager, quote, deployer, shares, seed, uint24(fee));
        bytes32 initHash = keccak256(abi.encodePacked(type(InverseHook).creationCode, args));
        (bytes32 salt, address predicted) =
            HookMiner.find(CREATE2_PROXY, initHash, vm.envOr("SALT_START", uint256(0)), 1_000_000);
        console2.log("Chain", block.chainid);
        console2.log("PoolManager", manager);
        console2.log("Predicted hook", predicted);
        console2.log("Seed quote (raw units; not deposited by this script)", seed);
        vm.startBroadcast(deployer);
        hook = new InverseHook{salt: salt}(
            IPoolManager(manager), IERC20Metadata(quote), deployer, shares, seed, uint24(fee)
        );
        vm.stopBroadcast();
        require(address(hook) == predicted, "CREATE2 proxy mismatch");
        console2.log("Token", address(hook.token()));
        console2.log("Gateway", address(hook.gateway()));
        console2.log("Hook", address(hook));
    }
}
