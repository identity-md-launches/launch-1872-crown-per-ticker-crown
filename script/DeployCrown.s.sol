// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";

/// @notice Post-launch operations for the owner, and the standing challenger token.
/// @dev The launch itself (token, registry, hook, pool) is deployed by IMD's factory from the
/// manifest; nothing here deploys those. Every step takes its configuration as arguments so tests
/// call the functions directly; `run` reads them from the environment for a real broadcast.
contract DeployCrown is Script {
    /// @notice Deploy the standing challenger candidate: a plain CRWN ERC-20 minted to `recipient`.
    function deployChallenger(address recipient) public returns (CrownChallengerToken) {
        return new CrownChallengerToken(recipient);
    }

    /// @notice Wire a launched hook to its registry and bind the launch pool to its ticker.
    /// Must be sent by the hook's owner.
    function configureHook(CrownHook hook, CrownRegistry registry, PoolKey memory key, bytes32 ticker, uint16 cutBps)
        public
    {
        if (address(hook.registry()) == address(0)) hook.setRegistry(registry);
        hook.registerPool(key, ticker, cutBps);
    }

    /// @notice Broadcast `deployChallenger` for CROWN_CHALLENGER_RECIPIENT.
    function run() external {
        address recipient = vm.envAddress("CROWN_CHALLENGER_RECIPIENT");
        vm.startBroadcast();
        deployChallenger(recipient);
        vm.stopBroadcast();
    }
}
