// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {InverseToken} from "../src/InverseToken.sol";
import {InverseMath} from "../src/libraries/InverseMath.sol";

abstract contract InverseDeploymentBase is Script {
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for *;

    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant ROBINHOOD_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    struct Config {
        IPoolManager manager;
        IERC20Metadata quote;
        address seeder;
        uint256 shares;
        uint256 seed;
        uint24 fee;
    }

    function _config() internal view returns (Config memory c) {
        uint256 chain = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == chain, "unexpected chain");
        require(chain == 4663 || chain == 46630 || chain == 31337, "unsupported chain");
        address manager = vm.envOr("POOL_MANAGER", chain == 4663 ? ROBINHOOD_MANAGER : address(0));
        require(manager.code.length > 0, "set a deployed PoolManager");
        if (chain == 4663) require(manager == ROBINHOOD_MANAGER, "mainnet requires canonical manager");
        c.manager = IPoolManager(manager);
        c.quote = IERC20Metadata(vm.envAddress("QUOTE_TOKEN"));
        c.seeder = vm.envAddress("DEPLOYER");
        c.shares = vm.envUint("INITIAL_SHARES");
        c.seed = vm.envUint("INITIAL_QUOTE");
        uint256 fee = vm.envOr("FEE_PPM", uint256(3000));
        require(c.seeder != address(0) && address(c.quote).code.length > 0, "set deployer and quote");
        require(fee < 1_000_000, "invalid fee");
        c.fee = uint24(fee);
        require(c.shares >= 1e18 && c.shares <= 1e30, "invalid initial shares");
        require(c.seed > 0 && c.seed <= type(uint112).max, "invalid seed quote");
        uint8 decimals = c.quote.decimals();
        require(decimals >= 6 && decimals <= 18, "unsupported quote decimals");
        uint256 price = FullMath.mulDiv(c.seed, 10 ** (18 - decimals) * 1e27, c.shares);
        require(price >= 1e18 && price <= 1e36, "initial price outside bounds");
        require(!c.manager.isUnlocked(), "manager is unlocked");
    }

    function _checkBindings(InverseHook hook, Config memory c) internal view {
        require(address(hook).code.length > 0, "hook missing");
        require(address(hook.poolManager()) == address(c.manager), "manager mismatch");
        require(address(hook.quoteToken()) == address(c.quote), "quote mismatch");
        require(hook.seeder() == c.seeder, "seeder mismatch");
        require(hook.initialShares() == c.shares && hook.initialQuote() == c.seed, "seed mismatch");
        require(hook.feePpm() == c.fee, "fee mismatch");
        InverseToken token = hook.token();
        require(
            address(token).code.length > 0 && address(hook.gateway()).code.length > 0, "component missing"
        );
        require(
            token.market() == address(hook) && token.gateway() == address(hook.gateway()), "token binding"
        );
        require(token.poolManager() == address(c.manager) && token.totalShares() == c.shares, "token config");
        require(address(hook.gateway().market()) == address(hook), "gateway binding");
        require(address(hook.gateway().poolManager()) == address(c.manager), "gateway manager");
        require(uint160(address(hook)) & 0x3fff == hook.HOOK_FLAGS(), "hook flags");
        require(PoolId.unwrap(hook.poolKey().toId()) == PoolId.unwrap(hook.poolId()), "pool key mismatch");
    }

    function _checkReady(InverseHook hook, Config memory c) internal view {
        _checkBindings(hook, c);
        require(hook.initialized() && hook.phase() == 0, "market not ready");
        InverseToken token = hook.token();
        require(!token.settlementActive() && !c.manager.isUnlocked(), "settlement open");
        require(token.sharesOf(address(c.manager)) == 0, "manager holds inverse shares");
        require(token.sharesOf(address(hook)) >= hook.reserveShares(), "share reserves underfunded");
        require(c.quote.balanceOf(address(hook)) >= hook.reserveQuote(), "quote reserves underfunded");
        require(
            token.indexRay()
                == InverseMath.index(hook.reserveShares(), hook.reserveQuote(), c.shares, c.seed),
            "index mismatch"
        );
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(c.manager, hook.poolId());
        require(sqrtPrice != 0, "v4 pool uninitialized");
        require(StateLibrary.getLiquidity(c.manager, hook.poolId()) == 0, "unexpected native liquidity");
    }

    /// @dev Integer amounts are serialized as decimal strings for lossless JavaScript consumption.
    function _report(InverseHook hook, Config memory c, string memory stage, bool transactionsPlanned)
        internal
        returns (string memory path)
    {
        string memory key = "inverse-deployment";
        vm.serializeString(key, "stage", stage);
        vm.serializeUint(key, "chainId", block.chainid);
        // Orbit's block.number may be the parent-chain estimate rather than the RPC L2 height.
        vm.serializeUint(key, "evmBlockNumber", block.number);
        vm.serializeAddress(key, "hook", address(hook));
        vm.serializeAddress(key, "token", address(hook.token()));
        vm.serializeAddress(key, "gateway", address(hook.gateway()));
        vm.serializeAddress(key, "poolManager", address(c.manager));
        vm.serializeAddress(key, "quoteToken", address(c.quote));
        vm.serializeAddress(key, "seeder", c.seeder);
        vm.serializeBytes32(key, "poolId", PoolId.unwrap(hook.poolId()));
        vm.serializeString(key, "initialShares", vm.toString(c.shares));
        vm.serializeString(key, "initialQuote", vm.toString(c.seed));
        vm.serializeUint(key, "quoteDecimals", c.quote.decimals());
        vm.serializeUint(key, "feePpm", c.fee);
        vm.serializeString(key, "reserveShares", vm.toString(hook.reserveShares()));
        vm.serializeString(key, "reserveQuote", vm.toString(hook.reserveQuote()));
        vm.serializeString(key, "indexRay", vm.toString(hook.token().indexRay()));
        vm.serializeString(key, "tokenPriceRay", vm.toString(hook.tokenPriceRay()));
        vm.serializeBool(key, "initialized", hook.initialized());
        vm.serializeBool(key, "permanentlyLockedLiquidity", true);
        string memory json = vm.serializeBool(key, "transactionsPlanned", transactionsPlanned);
        path = vm.envOr("DEPLOYMENT_REPORT", string("artifacts/deployment-plan.json"));
        vm.writeJson(json, path);
    }
}
