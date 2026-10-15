// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {CrownHook} from "../../src/CrownHook.sol";

/// @notice Mines a CREATE2 salt that lands `CrownHook` on an address carrying its permission bits.
library HookDeployer {
    uint160 internal constant CROWN_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    function deploy(IPoolManager manager, address owner) internal returns (CrownHook hook) {
        bytes memory creationCode = abi.encodePacked(type(CrownHook).creationCode, abi.encode(manager, owner));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, CROWN_FLAGS) || predicted.code.length != 0) continue;
            bytes32 salt = bytes32(i);
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            require(at == predicted, "hook deployment failed");
            return CrownHook(at);
        }
        revert("no salt found");
    }
}
