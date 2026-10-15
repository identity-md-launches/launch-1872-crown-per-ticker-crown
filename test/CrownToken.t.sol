// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownToken} from "../src/CrownToken.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract CrownTokenTest is Test {
    function test_launchTokenSupplyAndTransfer() public {
        CrownToken t = new CrownToken();
        assertEq(t.name(), "Crown Demo");
        assertEq(t.symbol(), "CRWN");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1_000_000_000e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18);
        assertTrue(t.transfer(address(0xCAFE), 1e18));
        assertEq(t.balanceOf(address(0xCAFE)), 1e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18 - 1e18);
        assertEq(t.totalSupply(), 1_000_000_000e18);
    }

    function test_launchTokenHasNoMint() public {
        CrownToken t = new CrownToken();
        (bool ok,) = address(t).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(t.totalSupply(), 1_000_000_000e18);
    }

    function test_challengerTokenMintsToRecipient() public {
        CrownChallengerToken c = new CrownChallengerToken(address(0xBEEF));
        assertEq(c.name(), "Crown Demo");
        assertEq(c.symbol(), "CRWN");
        assertEq(c.totalSupply(), 1_000_000_000e18);
        assertEq(c.balanceOf(address(0xBEEF)), 1_000_000_000e18);
    }

    function test_hookFlags() public pure {
        address a = address(uint160(0xABCD0000) | 0x10CC);
        assertEq(HookFlags.flagsOf(a), 0x10CC);
        assertTrue(HookFlags.matches(a, 0x10CC));
        assertTrue(HookFlags.matches(a, 0x10CC | (uint160(1) << 20)));
        assertFalse(HookFlags.matches(a, 0x10C0));
        assertEq(HookFlags.ALL, 0x3FFF);
    }
}
