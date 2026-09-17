// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutedProtocolFeesTest} from "./RoutedProtocolFees.t.sol";
import {RoutedInverseHook} from "../src/routed/RoutedInverseHook.sol";
import {MockQuote} from "./helpers/MockQuote.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Export execution-derived fixtures for the Kyber off-chain simulator.
/// Run: forge test --match-path test/RoutedKyberVectors.t.sol --match-test testExport
contract RoutedKyberVectorsTest is RoutedProtocolFeesTest {
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;
    uint256 private vector;

    function testExport() public {
        for (uint256 scenario; scenario < 4; ++scenario) {
            if (scenario != 0) _deploy();
            _fees(
                uint24(scenario * 333 + (scenario == 3 ? 1 : 0)), uint24(scenario == 0 ? 0 : 1001 - scenario)
            );
            for (uint256 i; i < 18; ++i) {
                bool buy = i % 3 != 2;
                uint256 amount = buy ? (i == 0 ? 1e14 : (i + 1) * 1734567890123) : token.balanceOf(alice) / 4;
                _export(buy, amount, uint8(i % 3 == 2 ? (i % 2 == 0 ? 14 : 0) : i % 2));
            }
            // Deliberately invalid: zero, reserve/delta limits, and tiny trades.
            _export(true, 0, 0);
            _export(true, 1, 0);
            _export(true, 1 << 128, 0);
            _export(false, type(uint112).max, 0);
            // Larger valid trades cross bitmap word boundaries.
            _export(true, 0.005 ether, 0);
            _export(false, token.balanceOf(alice) / 2, 14);
            uint256 snap = vm.snapshotState();
            stdstore.target(address(hook)).sig("roundingQuote()").checked_write(uint256(0));
            _export(true, 1e14, 0);
            uint256 nextVector = vector;
            vm.revertToState(snap);
            vector = nextVector;
            controller.configure(1, address(0));
            _export(false, token.balanceOf(alice) / 3, 14);
            controller.configure(0, address(0));
            _export(true, 1e19, 0);
            _export(true, 1e20, 0);
            _export(false, token.balanceOf(alice) / 7, 0);
        }
    }

    function _snapshot(string memory key) private returns (string memory result) {
        (uint160 sqrt, int24 tick, uint24 pf,) = manager.getSlot0(hook.poolId());
        (uint128 liq, uint256 last0, uint256 last1) =
            manager.getPositionInfo(hook.poolId(), address(hook), -887220, 887220, bytes32(0));
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthInside(hook.poolId(), -887220, 887220);
        uint256 f0;
        uint256 f1;
        unchecked {
            f0 = FullMath.mulDiv(growth0 - last0, liq, 1 << 128);
            f1 = FullMath.mulDiv(growth1 - last1, liq, 1 << 128);
        }
        vm.serializeUint(key, "version", 1);
        vm.serializeBool(key, "live", true);
        vm.serializeBool(key, "inverse0", address(token) < address(quote));
        vm.serializeBool(key, "feeControllerSupported", controller.mode() == 0);
        vm.serializeUint(key, "protocolFee", pf);
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeUint(key, "initialShares", hook.initialShares());
        vm.serializeUint(key, "initialQuote", hook.initialQuote());
        vm.serializeUint(key, "reserveShares", hook.reserveShares());
        vm.serializeUint(key, "reserveQuote", hook.reserveQuote());
        vm.serializeUint(key, "index", token.indexRay());
        vm.serializeUint(key, "custodiedShares", token.custodiedShares());
        vm.serializeUint(key, "nativeInverse", token.nativeBalance());
        vm.serializeUint(key, "hookQuote", quote.balanceOf(address(hook)));
        vm.serializeUint(key, "nativeQuote", hook.nativeQuote());
        vm.serializeUint(key, "roundingQuote", hook.roundingQuote());
        vm.serializeUint(key, "sqrtPriceX96", sqrt);
        vm.serializeUint(key, "liquidity", liq);
        vm.serializeUint(key, "fees0", f0);
        vm.serializeUint(key, "fees1", f1);
        vm.serializeUint(key, "sequence", hook.sequence());
        result = vm.serializeInt(key, "tick", tick);
    }

    function executeVector(bool buy, uint256 amount, uint8 mode) external {
        require(msg.sender == address(this));
        _swap(alice, buy, amount, 0, mode);
    }

    function _export(bool buy, uint256 amount, uint8 mode) private {
        string memory key = string.concat("vector-", vm.toString(vector));
        string memory beforeState = _snapshot(string.concat(key, "-before"));
        uint256 beforeBalance = buy ? token.balanceOf(alice) : quote.balanceOf(alice);
        uint256 beforeShares = token.sharesOf(alice);
        bool success;
        bytes memory reason;
        try this.executeVector(buy, amount, mode) {
            success = true;
        } catch (bytes memory e) {
            reason = e;
        }
        uint256 output;
        if (success) {
            output = buy
                ? FullMath.mulDiv(token.sharesOf(alice) - beforeShares, token.indexRay(), 1e27)
                : quote.balanceOf(alice) - beforeBalance;
        }
        vm.serializeString(key, "before", beforeState);
        vm.serializeBool(key, "zeroForOne", buy != (address(token) < address(quote)));
        vm.serializeUint(key, "amountIn", amount);
        vm.serializeUint(key, "settlementMode", mode);
        vm.serializeBool(key, "success", success);
        vm.serializeBytes(key, "revertData", reason);
        vm.serializeUint(key, "amountOut", output);
        string memory result = vm.serializeString(key, "after", _snapshot(string.concat(key, "-after")));
        vm.writeJson(
            result, string.concat("artifacts/kyber-vector-", suffix(), "-", vm.toString(vector++), ".json")
        );
    }

    function suffix() internal pure virtual returns (string memory) {
        return "normal";
    }
}

contract RoutedKyberVectorsInverse0Test is RoutedKyberVectorsTest {
    uint160 private quoteCounter;

    function _newQuote() internal override returns (MockQuote) {
        MockQuote q = new MockQuote(18);
        address target = address(type(uint160).max - 1 - quoteCounter++);
        vm.etch(target, address(q).code);
        return MockQuote(target);
    }

    function suffix() internal pure override returns (string memory) {
        return "inverse0";
    }
}
