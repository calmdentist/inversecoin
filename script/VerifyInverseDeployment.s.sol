// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {InverseHook} from "../src/InverseHook.sol";
import {InverseDeploymentBase} from "./InverseDeploymentBase.sol";

/// @notice Reads deployed network state only. Does not send transactions or perform explorer verification.
contract VerifyInverseDeployment is InverseDeploymentBase {
    function run() external {
        Config memory c = _config();
        InverseHook hook = InverseHook(vm.envAddress("INVERSE_HOOK"));
        _checkReady(hook, c);
        console2.log("Verified live market", address(hook));
        console2.log("Network-state report", _report(hook, c, "verified_on_chain", false));
    }
}
