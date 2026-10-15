// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Shared owner assertions: a launch contract is never owned by the factory that deployed
/// it, nor by the launch wallet standing at `tx.origin`.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` while the contracts are deployed.
    address internal constant ORIGIN_PROBE = address(0x000000000000000000000000000000000000aaaa);

    /// @dev Reads `owner()` when the contract has one and asserts it is neither the factory nor the
    /// launch wallet. A contract without `owner()` has nothing to check.
    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) return;
        address owner = abi.decode(data, (address));
        assertTrue(owner != factory, string.concat(name, " is owned by the launch factory"));
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
    }
}
