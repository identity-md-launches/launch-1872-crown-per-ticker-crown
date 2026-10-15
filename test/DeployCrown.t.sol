// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeployCrown} from "../script/DeployCrown.s.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {CrownToken} from "../src/CrownToken.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";

contract DeployCrownTest is Test {
    using PoolIdLibrary for PoolKey;

    function test_deployChallengerMintsToRecipient() public {
        DeployCrown s = new DeployCrown();
        CrownChallengerToken c = s.deployChallenger(address(0xBEEF));
        assertEq(c.balanceOf(address(0xBEEF)), 1_000_000_000e18);
        assertEq(c.symbol(), "CRWN");
    }

    function test_configureHookWiresRegistryAndPool() public {
        PoolManager manager = new PoolManager(address(this));
        CrownToken token = new CrownToken();
        address owner = makeAddr("owner");
        CrownRegistry registry = new CrownRegistry("CRWN", address(token), owner);
        CrownHook hook = HookDeployer.deploy(manager, owner);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, 79228162514264337593543950336);

        DeployCrown s = new DeployCrown();
        // The script must be the hook's owner: its setters are owner-only.
        bytes32 crwn = registry.tickerOf("CRWN");
        vm.expectRevert();
        s.configureHook(hook, registry, key, crwn, 100);

        vm.prank(owner);
        hook.transferOwnership(address(s));
        s.configureHook(hook, registry, key, registry.tickerOf("CRWN"), 100);
        assertEq(address(hook.registry()), address(registry));
        (, bytes32 ticker, uint16 bps) = hook.pools(key.toId());
        assertEq(ticker, keccak256("CRWN"));
        assertEq(bps, 100);
    }
}
