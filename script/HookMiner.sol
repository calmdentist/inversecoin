// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Off-chain script utility. Hash initcode once, then mine the v4 permission bits.
library HookMiner {
    uint160 internal constant FLAGS = 0x2aa8;
    uint160 internal constant MASK = 0x3fff;
    error SaltNotFound();

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i = start; i < start + attempts; ++i) {
            salt = bytes32(i);
            predicted = compute(deployer, salt, initCodeHash);
            if (uint160(predicted) & MASK == FLAGS && predicted.code.length == 0) return (salt, predicted);
        }
        revert SaltNotFound();
    }

    function compute(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev Includes occupied addresses so reruns resolve the same deployment instead of creating another.
    function findDeterministic(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i = start; i < start + attempts; ++i) {
            salt = bytes32(i);
            predicted = compute(deployer, salt, initCodeHash);
            if (uint160(predicted) & MASK == FLAGS) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
