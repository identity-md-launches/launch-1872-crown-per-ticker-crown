// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownRegistry} from "src/CrownRegistry.sol";
import {CrownToken} from "src/CrownToken.sol";
import {CrownChallengerToken} from "src/CrownChallengerToken.sol";

contract ClaimReceiver {
    CrownRegistry public immutable registry;
    uint256 public challengeId;
    bool public reject;
    bool public reenter;
    bool public reentrySucceeded;
    uint256 public received;

    constructor(CrownRegistry registry_) {
        registry = registry_;
    }

    function configure(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    function stake(uint256 id) external payable {
        challengeId = id;
        registry.stake{value: msg.value}(id, CrownRegistry.Side.King);
    }

    function claim() external {
        registry.claim(challengeId);
    }

    receive() external payable {
        require(!reject, "receiver rejects");
        received += msg.value;
        if (reenter) {
            (reentrySucceeded,) = address(registry).call(abi.encodeCall(registry.claim, (challengeId)));
        }
    }
}

contract TreasuryRejectReceiver {
    receive() external payable {
        revert("treasury rejects");
    }
}

contract CrownRegistryBoundariesTest is Test {
    bytes32 constant TICKER = keccak256("CRWN");
    CrownRegistry registry;
    CrownToken token;
    CrownChallengerToken rival;
    address opener = makeAddr("boundary-opener");
    address alice = makeAddr("boundary-alice");
    address bob = makeAddr("boundary-bob");
    address carol = makeAddr("boundary-carol");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new CrownToken();
        rival = new CrownChallengerToken(opener);
        registry = new CrownRegistry("CRWN", address(token), alice);
        vm.deal(opener, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(address(this), 100 ether);
        vm.warp(block.timestamp + 7 days);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(opener);
        return registry.openChallenge{value: 0.01 ether}(TICKER, address(rival));
    }

    function _stake(uint256 id, address who, CrownRegistry.Side side, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(who);
        registry.stake{value: amount}(id, side);
    }

    function _finalize(uint256 id) internal {
        vm.warp(registry.challenges(id).finalizeAfter);
        // Neither the opener nor the beneficiary has special resolution powers.
        vm.prank(carol);
        registry.finalize(id);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_wrongBondIsAtomic(uint96 sentSeed) public {
        uint256 sent = bound(sentSeed, 0, 0.02 ether);
        if (sent == 0.01 ether) sent++;
        uint256 before = opener.balance;
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WrongBond.selector, sent, 0.01 ether));
        registry.openChallenge{value: sent}(TICKER, address(rival));
        assertEq(opener.balance, before);
        assertEq(address(registry).balance, 0);
        assertEq(registry.challengeCount(), 0);
        assertEq(registry.liveChallenge(TICKER), 0);
        (uint256 opened,, uint256 kings, uint256 challengers) = registry.tickerTotals(TICKER);
        assertEq(opened + kings + challengers, 0);
    }

    function test_bondOneWeiEitherSideRejected() public {
        vm.startPrank(opener);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WrongBond.selector, 0.01 ether - 1, 0.01 ether));
        registry.openChallenge{value: 0.01 ether - 1}(TICKER, address(rival));
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WrongBond.selector, 0.01 ether + 1, 0.01 ether));
        registry.openChallenge{value: 0.01 ether + 1}(TICKER, address(rival));
        vm.stopPrank();
        _open();
        assertEq(registry.challengerStakeOf(1, opener), 0.01 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quorumWithinOneWei(uint8 offsetSeed) public {
        uint256 total = 0.05 ether - 1 + (offsetSeed % 3);
        uint256 id = _open();
        _stake(id, alice, CrownRegistry.Side.King, 0.02 ether);
        _stake(id, bob, CrownRegistry.Side.Challenger, total - 0.03 ether);
        _finalize(id);
        bool won = total >= 0.05 ether;
        assertEq(registry.challenges(id).challengerWon, won);
        assertEq(registry.king(TICKER).token, won ? address(rival) : address(token));
        assertEq(registry.king(TICKER).beneficiary, won ? opener : alice);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strictLeadWithinOneWei(uint8 offsetSeed) public {
        uint256 challengerTotal = 0.03 ether - 1 + (offsetSeed % 3);
        uint256 id = _open();
        _stake(id, alice, CrownRegistry.Side.King, 0.03 ether);
        _stake(id, bob, CrownRegistry.Side.Challenger, challengerTotal - 0.01 ether);
        _finalize(id);
        assertEq(registry.challenges(id).challengerWon, challengerTotal > 0.03 ether);
    }

    function test_oddWeiSlashAndPerStakerRounding() public {
        uint256 id = _open();
        _stake(id, alice, CrownRegistry.Side.King, 7);
        _stake(id, bob, CrownRegistry.Side.King, 8);
        _stake(id, opener, CrownRegistry.Side.Challenger, 0.01 ether);
        _stake(id, carol, CrownRegistry.Side.Challenger, 0.04 ether);
        _finalize(id);
        // Losing total 15 wei: slash 3; winner pool 1; treasury 2.
        // Refunds floor independently: floor(7*4/5)=5, floor(8*4/5)=6.
        assertEq(registry.challenges(id).winnerBonus, 1);
        assertEq(registry.treasuryOwed(), 2);
        assertEq(registry.claimable(id, alice), 5);
        assertEq(registry.claimable(id, bob), 6);
        assertEq(registry.claimable(id, opener), 0.02 ether);
        assertEq(registry.claimable(id, carol), 0.04 ether);
        _pull(id, alice, 5);
        _pull(id, bob, 6);
        _pull(id, opener, 0.02 ether);
        _pull(id, carol, 0.04 ether);
        uint256 treasuryBefore = registry.TREASURY().balance;
        registry.withdrawTreasury();
        assertEq(registry.TREASURY().balance - treasuryBefore, 2);
        assertEq(address(registry).balance, 2, "only two independently rounded wei remain");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_slashAndRefundsForEitherWinner(uint96 kingSeed, uint96 challengerSeed) public {
        uint256 kingTotal = bound(kingSeed, 0, 1 ether);
        uint256 challengerExtra = bound(challengerSeed, 0, 1 ether);
        uint256 challengerTotal = 0.01 ether + challengerExtra;
        uint256 id = _open();
        _stake(id, alice, CrownRegistry.Side.King, kingTotal);
        // Aggregate repeated stakes for the same wallet before computing its pro-rata claim.
        _stake(id, opener, CrownRegistry.Side.Challenger, challengerExtra);
        _finalize(id);
        bool flip = challengerTotal > kingTotal && kingTotal + challengerTotal >= 0.05 ether;
        (uint256 kingClaim, uint256 challengerClaim, uint256 treasury) = _expected(kingTotal, challengerTotal, flip);
        assertEq(registry.challenges(id).challengerWon, flip);
        if (flip || kingTotal != 0) {
            assertEq(registry.challenges(id).winnerBonus, ((flip ? kingTotal : challengerTotal) / 5) / 2);
        } else {
            assertEq(registry.challenges(id).winnerBonus, 0);
        }
        assertEq(registry.treasuryOwed(), treasury);
        assertEq(registry.claimable(id, alice), kingClaim);
        assertEq(registry.claimable(id, opener), challengerClaim);
        if (kingClaim > 0) _pull(id, alice, kingClaim);
        if (challengerClaim > 0) _pull(id, opener, challengerClaim);
        if (treasury > 0) registry.withdrawTreasury();
        assertEq(address(registry).balance, kingTotal + challengerTotal - kingClaim - challengerClaim - treasury);
        assertLe(address(registry).balance, 1, "one losing account can leave at most one refund wei");
    }

    function _expected(uint256 kingTotal, uint256 challengerTotal, bool flip)
        internal
        pure
        returns (uint256 kingClaim, uint256 challengerClaim, uint256 treasury)
    {
        uint256 losing = flip ? kingTotal : challengerTotal;
        uint256 winning = flip ? challengerTotal : kingTotal;
        // Use division by five, independently of the contract's bps representation.
        uint256 slash = losing / 5;
        uint256 bonus = winning == 0 ? 0 : slash / 2;
        treasury = slash - bonus;
        kingClaim = flip ? kingTotal * 4 / 5 : kingTotal + bonus;
        challengerClaim = flip ? challengerTotal + bonus : challengerTotal * 4 / 5;
    }

    function test_failedChallengeCooldownIsTickerLocal() public {
        bytes32 other = keccak256("OTHER");
        registry.registerKing(other, address(token), bob);
        vm.warp(block.timestamp + 7 days);
        uint256 id = _open();
        _finalize(id);
        vm.prank(opener);
        registry.openChallenge{value: 0.01 ether}(other, address(rival));
        uint64 until = registry.cooldownUntil(TICKER);
        vm.warp(until - 1);
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.InCooldown.selector, until));
        registry.openChallenge{value: 0.01 ether}(TICKER, address(rival));
        vm.warp(until);
        _open();
        assertTrue(registry.hasLiveChallenge(other));
        assertTrue(registry.hasLiveChallenge(TICKER));
    }

    function test_successfulFlipRestartsMinimumReign() public {
        uint256 id = _open();
        _stake(id, bob, CrownRegistry.Side.Challenger, 0.04 ether);
        _finalize(id);
        uint64 next = uint64(vm.getBlockTimestamp() + 7 days);
        vm.warp(next - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.ReignTooYoung.selector, next));
        registry.openChallenge{value: 0.01 ether}(TICKER, address(token));
        vm.warp(next);
        vm.prank(alice);
        uint256 second = registry.openChallenge{value: 0.01 ether}(TICKER, address(token));
        assertEq(second, id + 1);
        assertEq(registry.challenges(id).challengerToken, address(rival), "past challenge is immutable");
    }

    function test_rejectedClaimRollsBackAndCanBeRetried() public {
        uint256 id = _open();
        ClaimReceiver receiver = new ClaimReceiver(registry);
        receiver.stake{value: 0.05 ether}(id);
        _finalize(id);
        receiver.configure(true, false);
        uint256 balance = address(registry).balance;
        vm.expectRevert(CrownRegistry.TransferFailed.selector);
        receiver.claim();
        assertFalse(registry.claimed(id, address(receiver)));
        assertEq(address(registry).balance, balance);
        assertEq(registry.claimable(id, address(receiver)), 0.051 ether);
        // Another staker can pull while the rejecting account's payout is still outstanding.
        _pull(id, opener, 0.008 ether);
        receiver.configure(false, false);
        receiver.claim();
        assertEq(receiver.received(), 0.051 ether);
        assertEq(registry.claimable(id, address(receiver)), 0);
    }

    function test_reentrantClaimCannotWithdrawTwice() public {
        uint256 id = _open();
        ClaimReceiver receiver = new ClaimReceiver(registry);
        receiver.stake{value: 0.05 ether}(id);
        _finalize(id);
        receiver.configure(false, true);
        receiver.claim();
        assertFalse(receiver.reentrySucceeded());
        assertEq(receiver.received(), 0.051 ether);
        assertTrue(registry.claimed(id, address(receiver)));
        _pull(id, opener, 0.008 ether);
        registry.withdrawTreasury();
        assertEq(address(registry).balance, 0);
    }

    function test_rejectedTreasuryTransferPreservesDebt() public {
        uint256 id = _open();
        _finalize(id);
        TreasuryRejectReceiver rejecter = new TreasuryRejectReceiver();
        address treasury = registry.TREASURY();
        vm.etch(treasury, address(rejecter).code);
        vm.expectRevert(CrownRegistry.TransferFailed.selector);
        registry.withdrawTreasury();
        assertEq(registry.treasuryOwed(), 0.002 ether);
        assertEq(address(registry).balance, 0.01 ether);
        _pull(id, opener, 0.008 ether);
        vm.etch(treasury, hex"");
        uint256 before = treasury.balance;
        vm.prank(carol);
        registry.withdrawTreasury();
        assertEq(treasury.balance - before, 0.002 ether);
        assertEq(registry.treasuryOwed(), 0);
        assertEq(address(registry).balance, 0);
    }

    function test_timelockHasNoLateStakeEscape() public {
        uint256 id = _open();
        CrownRegistry.Challenge memory c = registry.challenges(id);
        vm.warp(c.windowEnd - 1);
        _stake(id, alice, CrownRegistry.Side.King, 1);
        vm.warp(c.windowEnd);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WindowClosed.selector, c.windowEnd));
        registry.stake{value: 0.04 ether}(id, CrownRegistry.Side.Challenger);
        vm.warp(c.finalizeAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.TooEarly.selector, c.finalizeAfter));
        registry.finalize(id);
        _finalize(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.WindowClosed.selector, c.windowEnd));
        registry.stake{value: 1}(id, CrownRegistry.Side.Challenger);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.AlreadyFinalized.selector, id));
        registry.finalize(id);
    }

    function _pull(uint256 id, address who, uint256 expected) internal {
        uint256 before = who.balance;
        vm.prank(who);
        registry.claim(id);
        assertEq(who.balance - before, expected);
        assertEq(registry.claimable(id, who), 0);
    }
}
