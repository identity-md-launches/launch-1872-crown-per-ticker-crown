// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {ThroneRegistry} from "../src/ThroneRegistry.sol";
import {ICrownRegistry} from "../src/interfaces/ICrownRegistry.sol";

contract CrownRegistryTest is Test {
    CrownRegistry registry;

    bytes32 constant CRWN = keccak256("CRWN");
    address constant KING_TOKEN = address(0x1111);
    address constant KING_WALLET = address(0x2222);
    address constant CHAL_TOKEN = address(0x3333);
    address challenger = makeAddr("challenger");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        registry = new CrownRegistry("crwn", KING_TOKEN, KING_WALLET);
        vm.deal(challenger, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    function _warpChallengeable() internal {
        vm.warp(T0 + registry.MIN_REIGN());
    }

    function _open() internal returns (uint256 id) {
        _warpChallengeable();
        uint256 bond = registry.BOND();
        vm.prank(challenger);
        id = registry.openChallenge{value: bond}(CRWN, CHAL_TOKEN);
    }

    function _finalize(uint256 id) internal {
        CrownRegistry.Challenge memory c = registry.challenges(id);
        vm.warp(c.finalizeAfter);
        registry.finalize(id);
    }

    // ------------------------------------------------------------ constructor & registerKing

    function test_genesisCrown() public view {
        ICrownRegistry.King memory k = registry.king(CRWN);
        assertEq(k.token, KING_TOKEN);
        assertEq(k.beneficiary, KING_WALLET);
        assertEq(k.reignStartedAt, T0);
        assertEq(registry.tickerOf("crwn"), CRWN);
        assertEq(registry.tickerOf("CrWn"), CRWN);
    }

    function test_constructorWithoutGenesis() public {
        CrownRegistry r = new CrownRegistry("", address(0), address(0));
        assertEq(r.king(CRWN).token, address(0));
    }

    function test_constructorRejectsHalfGenesis() public {
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        new CrownRegistry("CRWN", KING_TOKEN, address(0));
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        new CrownRegistry("CRWN", address(0), KING_WALLET);
    }

    function test_throneRegistryIsTheSameContract() public {
        ThroneRegistry t = new ThroneRegistry("CRWN", KING_TOKEN, KING_WALLET);
        assertEq(t.king(CRWN).token, KING_TOKEN);
        assertEq(t.BOND(), 0.01 ether);
    }

    function test_registerKingFirstComeOnly() public {
        bytes32 abc = registry.tickerOf("abc");
        vm.expectEmit(true, true, true, true);
        emit CrownRegistry.Crowned(abc, address(0xA), address(0xB), uint64(T0));
        registry.registerKing(abc, address(0xA), address(0xB));
        assertEq(registry.king(abc).token, address(0xA));

        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.AlreadyCrowned.selector, abc));
        registry.registerKing(abc, address(0xC), address(0xD));
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.AlreadyCrowned.selector, CRWN));
        registry.registerKing(CRWN, address(0xC), address(0xD));
    }

    function test_registerKingRejectsZeroes() public {
        vm.expectRevert(CrownRegistry.ZeroTicker.selector);
        registry.registerKing(bytes32(0), address(0xA), address(0xB));
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        registry.registerKing(keccak256("X"), address(0), address(0xB));
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        registry.registerKing(keccak256("X"), address(0xA), address(0));
    }

    // ------------------------------------------------------------ openChallenge

    function test_openChallengeRequiresMinReign() public {
        vm.warp(T0 + registry.MIN_REIGN() - 1);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.ReignTooYoung.selector, uint64(T0 + 7 days)));
        registry.openChallenge{value: 0.01 ether}(CRWN, CHAL_TOKEN);
    }

    function test_openChallengeRequiresExactBond() public {
        _warpChallengeable();
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WrongBond.selector, 0.02 ether, 0.01 ether));
        registry.openChallenge{value: 0.02 ether}(CRWN, CHAL_TOKEN);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WrongBond.selector, 0, 0.01 ether));
        registry.openChallenge(CRWN, CHAL_TOKEN);
    }

    function test_openChallengeRejectsUnknownTickerSameTokenAndZero() public {
        _warpChallengeable();
        bytes32 nope = keccak256("NOPE");
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.NotCrowned.selector, nope));
        registry.openChallenge{value: 0.01 ether}(nope, CHAL_TOKEN);
        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.SameToken.selector);
        registry.openChallenge{value: 0.01 ether}(CRWN, KING_TOKEN);
        vm.prank(challenger);
        vm.expectRevert(CrownRegistry.ZeroAddress.selector);
        registry.openChallenge{value: 0.01 ether}(CRWN, address(0));
    }

    function test_openChallengeRecordsStateAndBondAsStake() public {
        _warpChallengeable();
        uint64 now_ = uint64(block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit CrownRegistry.ChallengeOpened(1, CRWN, CHAL_TOKEN, challenger, now_ + 72 hours, now_ + 96 hours);
        vm.expectEmit(true, true, true, true);
        emit CrownRegistry.Staked(1, challenger, CrownRegistry.Side.Challenger, 0.01 ether);
        vm.prank(challenger);
        uint256 id = registry.openChallenge{value: 0.01 ether}(CRWN, CHAL_TOKEN);
        assertEq(id, 1);
        CrownRegistry.Challenge memory c = registry.challenges(id);
        assertEq(c.ticker, CRWN);
        assertEq(c.challengerToken, CHAL_TOKEN);
        assertEq(c.challengerBeneficiary, challenger);
        assertEq(c.openedAt, now_);
        assertEq(c.windowEnd, now_ + 72 hours);
        assertEq(c.finalizeAfter, now_ + 96 hours);
        assertEq(c.challengerStake, 0.01 ether);
        assertEq(c.kingStake, 0);
        assertEq(registry.challengerStakeOf(id, challenger), 0.01 ether);
        assertEq(registry.liveChallenge(CRWN), id);
        assertTrue(registry.hasLiveChallenge(CRWN));
        (uint256 opened,,, uint256 chalEver) = registry.tickerTotals(CRWN);
        assertEq(opened, 1);
        assertEq(chalEver, 0.01 ether);
    }

    function test_oneLiveChallengePerTicker() public {
        uint256 id = _open();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.ChallengeLive.selector, CRWN, id));
        registry.openChallenge{value: 0.01 ether}(CRWN, address(0x4444));
    }

    // ------------------------------------------------------------ stake

    function test_stakeDuringWindowOnly() public {
        uint256 id = _open();
        CrownRegistry.Challenge memory c = registry.challenges(id);

        vm.prank(alice);
        registry.stake{value: 0.02 ether}(id, CrownRegistry.Side.King);
        vm.warp(c.windowEnd - 1);
        vm.prank(bob);
        registry.stake{value: 0.03 ether}(id, CrownRegistry.Side.Challenger);

        vm.warp(c.windowEnd);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WindowClosed.selector, c.windowEnd));
        registry.stake{value: 0.01 ether}(id, CrownRegistry.Side.Challenger);

        c = registry.challenges(id);
        assertEq(c.kingStake, 0.02 ether);
        assertEq(c.challengerStake, 0.04 ether);
        assertEq(registry.kingStakeOf(id, alice), 0.02 ether);
        assertEq(registry.challengerStakeOf(id, bob), 0.03 ether);
    }

    function test_stakeRejectsZeroAndUnknown() public {
        uint256 id = _open();
        vm.prank(alice);
        vm.expectRevert(CrownRegistry.ZeroStake.selector);
        registry.stake(id, CrownRegistry.Side.King);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.UnknownChallenge.selector, 42));
        registry.stake{value: 1}(42, CrownRegistry.Side.King);
    }

    // ------------------------------------------------------------ finalize

    function test_finalizeRespectsTimelock() public {
        uint256 id = _open();
        CrownRegistry.Challenge memory c = registry.challenges(id);
        vm.warp(c.windowEnd);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.TooEarly.selector, c.finalizeAfter));
        registry.finalize(id);
        vm.warp(c.finalizeAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.TooEarly.selector, c.finalizeAfter));
        registry.finalize(id);
        vm.warp(c.finalizeAfter);
        registry.finalize(id);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.AlreadyFinalized.selector, id));
        registry.finalize(id);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.UnknownChallenge.selector, 9));
        registry.finalize(9);
    }

    /// @dev king 0.02 vs challenger 0.05 (bond 0.01 + 0.01 + bob 0.03): challenger wins, exact wei.
    function test_dethroneMathExact() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.stake{value: 0.02 ether}(id, CrownRegistry.Side.King);
        vm.prank(challenger);
        registry.stake{value: 0.01 ether}(id, CrownRegistry.Side.Challenger);
        vm.prank(bob);
        registry.stake{value: 0.03 ether}(id, CrownRegistry.Side.Challenger);

        CrownRegistry.Challenge memory c = registry.challenges(id);
        vm.warp(c.finalizeAfter);
        vm.expectEmit(true, true, true, true);
        emit CrownRegistry.Dethroned(id, CRWN, CHAL_TOKEN, KING_TOKEN, 0.02 ether, 0.05 ether);
        vm.expectEmit(true, true, true, true);
        emit CrownRegistry.Crowned(CRWN, CHAL_TOKEN, challenger, uint64(c.finalizeAfter));
        registry.finalize(id);

        ICrownRegistry.King memory k = registry.king(CRWN);
        assertEq(k.token, CHAL_TOKEN);
        assertEq(k.beneficiary, challenger);
        assertEq(k.reignStartedAt, c.finalizeAfter);
        assertEq(registry.liveChallenge(CRWN), 0);
        assertFalse(registry.hasLiveChallenge(CRWN));
        assertEq(registry.cooldownUntil(CRWN), 0);
        (, uint256 dethronements,,) = registry.tickerTotals(CRWN);
        assertEq(dethronements, 1);

        // losing side 0.02: slash 0.004, 0.002 to winners, 0.002 to treasury; alice refunded 0.016.
        c = registry.challenges(id);
        assertTrue(c.finalized);
        assertTrue(c.challengerWon);
        assertEq(c.winnerBonus, 0.002 ether);
        assertEq(registry.treasuryOwed(), 0.002 ether);
        assertEq(registry.claimable(id, alice), 0.016 ether);
        // winners: challenger 0.02 of 0.05 -> +0.0008; bob 0.03 of 0.05 -> +0.0012.
        assertEq(registry.claimable(id, challenger), 0.0208 ether);
        assertEq(registry.claimable(id, bob), 0.0312 ether);
        assertEq(
            registry.claimable(id, alice) + registry.claimable(id, challenger) + registry.claimable(id, bob)
                + registry.treasuryOwed(),
            0.07 ether
        );

        // Pull payments land exactly.
        uint256 before = alice.balance;
        vm.prank(alice);
        registry.claim(id);
        assertEq(alice.balance - before, 0.016 ether);
        before = challenger.balance;
        vm.prank(challenger);
        registry.claim(id);
        assertEq(challenger.balance - before, 0.0208 ether);
        before = bob.balance;
        vm.prank(bob);
        registry.claim(id);
        assertEq(bob.balance - before, 0.0312 ether);
        before = registry.TREASURY().balance;
        registry.withdrawTreasury();
        assertEq(registry.TREASURY().balance - before, 0.002 ether);
        assertEq(address(registry).balance, 0);
    }

    /// @dev king 0.05 vs challenger 0.01: king holds, cooldown starts, exact wei.
    function test_challengeFailsWhenKingOutStakes() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.stake{value: 0.05 ether}(id, CrownRegistry.Side.King);
        CrownRegistry.Challenge memory c = registry.challenges(id);
        vm.warp(c.finalizeAfter);
        vm.expectEmit(true, true, true, true);
        emit CrownRegistry.ChallengeFailed(id, CRWN, 0.05 ether, 0.01 ether);
        registry.finalize(id);

        assertEq(registry.king(CRWN).token, KING_TOKEN);
        assertEq(registry.king(CRWN).beneficiary, KING_WALLET);
        assertEq(registry.king(CRWN).reignStartedAt, T0, "reign is not reset by a failed challenge");
        assertEq(registry.cooldownUntil(CRWN), c.finalizeAfter + 3 days);
        // losing side 0.01: slash 0.002, 0.001 to alice, 0.001 to treasury; challenger refunded 0.008.
        assertEq(registry.claimable(id, alice), 0.051 ether);
        assertEq(registry.claimable(id, challenger), 0.008 ether);
        assertEq(registry.treasuryOwed(), 0.001 ether);

        // Cooldown blocks a new challenge until it lapses.
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.InCooldown.selector, uint64(c.finalizeAfter + 3 days)));
        registry.openChallenge{value: 0.01 ether}(CRWN, CHAL_TOKEN);
        vm.warp(c.finalizeAfter + 3 days);
        vm.prank(challenger);
        uint256 id2 = registry.openChallenge{value: 0.01 ether}(CRWN, CHAL_TOKEN);
        assertEq(id2, 2);
    }

    /// @dev challenger 0.03 > king 0.01 but total 0.04 < quorum 0.05: the challenge fails.
    function test_challengeFailsWithoutQuorum() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.stake{value: 0.01 ether}(id, CrownRegistry.Side.King);
        vm.prank(bob);
        registry.stake{value: 0.02 ether}(id, CrownRegistry.Side.Challenger);
        _finalize(id);

        assertEq(registry.king(CRWN).token, KING_TOKEN);
        // losing side 0.03: slash 0.006, 0.003 to alice, 0.003 to treasury.
        assertEq(registry.claimable(id, alice), 0.013 ether);
        assertEq(registry.claimable(id, challenger), 0.008 ether);
        assertEq(registry.claimable(id, bob), 0.016 ether);
        assertEq(registry.treasuryOwed(), 0.003 ether);
    }

    /// @dev Exactly at quorum with the challenger ahead flips; a tie does not.
    function test_quorumBoundaryAndTie() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.stake{value: 0.02 ether}(id, CrownRegistry.Side.King);
        vm.prank(bob);
        registry.stake{value: 0.02 ether}(id, CrownRegistry.Side.Challenger);
        _finalize(id);
        assertEq(registry.king(CRWN).token, CHAL_TOKEN, "0.03 > 0.02 at exactly 0.05 total flips");

        // Second ticker: a tie never flips.
        bytes32 tie = keccak256("TIE");
        registry.registerKing(tie, address(0xA), address(0xB));
        vm.warp(block.timestamp + 7 days);
        vm.prank(challenger);
        uint256 id2 = registry.openChallenge{value: 0.01 ether}(tie, address(0xC));
        vm.prank(alice);
        registry.stake{value: 0.03 ether}(id2, CrownRegistry.Side.King);
        vm.prank(bob);
        registry.stake{value: 0.02 ether}(id2, CrownRegistry.Side.Challenger);
        _finalize(id2);
        assertEq(registry.king(tie).token, address(0xA));
    }

    /// @dev Nobody staked for the king and the challenge fails: the whole slash goes to the treasury.
    function test_slashGoesToTreasuryWhenWinningSideIsEmpty() public {
        uint256 id = _open();
        _finalize(id);
        assertEq(registry.king(CRWN).token, KING_TOKEN);
        assertEq(registry.treasuryOwed(), 0.002 ether);
        assertEq(registry.claimable(id, challenger), 0.008 ether);
        assertEq(registry.challenges(id).winnerBonus, 0);
    }

    // ------------------------------------------------------------ claims

    function test_claimIsPullOnceAndOnlyAfterFinalize() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.stake{value: 0.05 ether}(id, CrownRegistry.Side.King);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.NotFinalized.selector, id));
        registry.claim(id);
        _finalize(id);

        vm.prank(alice);
        registry.claim(id);
        assertEq(registry.claimable(id, alice), 0);
        vm.prank(alice);
        vm.expectRevert(CrownRegistry.NothingToClaim.selector);
        registry.claim(id);
        vm.prank(bob);
        vm.expectRevert(CrownRegistry.NothingToClaim.selector);
        registry.claim(id);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.UnknownChallenge.selector, 7));
        registry.claim(7);
    }

    function test_stakerOnBothSidesClaimsBoth() public {
        uint256 id = _open();
        vm.prank(alice);
        registry.stake{value: 0.01 ether}(id, CrownRegistry.Side.King);
        vm.prank(alice);
        registry.stake{value: 0.04 ether}(id, CrownRegistry.Side.Challenger);
        _finalize(id);
        assertEq(registry.king(CRWN).token, CHAL_TOKEN);
        // losing king 0.01: slash 0.002 -> 0.001 winners, 0.001 treasury. alice: 0.008 + 0.04 + 0.001*0.04/0.05.
        assertEq(registry.claimable(id, alice), 0.008 ether + 0.04 ether + 0.0008 ether);
        assertEq(registry.claimable(id, challenger), 0.01 ether + 0.0002 ether);
    }

    function test_claimRevertsForRejectingReceiver() public {
        Rejecter r = new Rejecter();
        vm.deal(address(r), 1 ether);
        uint256 id = _open();
        r.stakeOn(registry, id, CrownRegistry.Side.King, 0.05 ether);
        _finalize(id);
        vm.prank(address(r));
        vm.expectRevert(CrownRegistry.TransferFailed.selector);
        registry.claim(id);
        assertEq(registry.claimable(id, address(r)), 0.051 ether, "a failed pull stays claimable");
    }

    function test_withdrawTreasuryNeedsSomething() public {
        vm.expectRevert(CrownRegistry.NothingToClaim.selector);
        registry.withdrawTreasury();
    }

    /// @dev Conservation of funds under arbitrary stakes: the contract never owes more than it
    /// holds, and the difference is only rounding dust (under one wei per stake share), which
    /// stays in the contract.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_conservation(uint96 kA, uint96 kB, uint96 cA, uint96 cB) public {
        kA = uint96(bound(kA, 0, 5 ether));
        kB = uint96(bound(kB, 0, 5 ether));
        cA = uint96(bound(cA, 0, 5 ether));
        cB = uint96(bound(cB, 0, 5 ether));
        uint256 id = _open();
        if (kA > 0) {
            vm.prank(alice);
            registry.stake{value: kA}(id, CrownRegistry.Side.King);
        }
        if (kB > 0) {
            vm.prank(bob);
            registry.stake{value: kB}(id, CrownRegistry.Side.King);
        }
        if (cA > 0) {
            vm.prank(alice);
            registry.stake{value: cA}(id, CrownRegistry.Side.Challenger);
        }
        if (cB > 0) {
            vm.prank(bob);
            registry.stake{value: cB}(id, CrownRegistry.Side.Challenger);
        }
        uint256 total = 0.01 ether + uint256(kA) + kB + cA + cB;
        assertEq(address(registry).balance, total);
        _finalize(id);

        uint256 kingTotal = uint256(kA) + kB;
        uint256 chalTotal = 0.01 ether + uint256(cA) + cB;
        bool flipped = chalTotal > kingTotal && total >= 0.05 ether;
        assertEq(registry.king(CRWN).token == CHAL_TOKEN, flipped);

        uint256 owed = registry.claimable(id, alice) + registry.claimable(id, bob) + registry.claimable(id, challenger)
            + registry.treasuryOwed();
        assertLe(owed, total);
        // Three stakers, each possibly on both sides: at most one wei of dust per share.
        assertLt(total - owed, 6, "dust exceeds one wei per stake share");

        uint256 losing = flipped ? kingTotal : chalTotal;
        assertEq(registry.treasuryOwed(), (losing * 2000 / 10000) - registry.challenges(id).winnerBonus);

        if (registry.claimable(id, alice) > 0) {
            vm.prank(alice);
            registry.claim(id);
        }
        if (registry.claimable(id, bob) > 0) {
            vm.prank(bob);
            registry.claim(id);
        }
        if (registry.claimable(id, challenger) > 0) {
            vm.prank(challenger);
            registry.claim(id);
        }
        if (registry.treasuryOwed() > 0) registry.withdrawTreasury();
        assertEq(address(registry).balance, total - owed);
    }
}

contract Rejecter {
    function stakeOn(CrownRegistry r, uint256 id, CrownRegistry.Side side, uint256 amount) external {
        r.stake{value: amount}(id, side);
    }
}
