// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrownRegistry} from "src/CrownRegistry.sol";
import {ICrownRegistry} from "src/interfaces/ICrownRegistry.sol";
import {CrownToken} from "src/CrownToken.sol";
import {CrownChallengerToken} from "src/CrownChallengerToken.sol";

/// @dev All escrow enters through this handler. The model records inputs and computes liabilities
/// independently; it never uses claimable(), challenge stakes, or registry balances as its oracle.
contract CrownRegistryHandler is Test {
    struct Round {
        uint256 tickerIndex;
        uint64 opened;
        address candidate;
        address beneficiary;
        uint256 kingTotal;
        uint256 challengerTotal;
        uint256[4] kings;
        uint256[4] challengers;
        bool[4] pulled;
        bool done;
        bool won;
    }

    CrownRegistry public immutable registry;
    address[4] public actors;
    address[2] public tokens;
    bytes32[2] public tickers;
    address[2] public expectedKing;
    address[2] public expectedBeneficiary;
    uint64[2] public expectedReign;
    uint64[2] public expectedCooldown;
    uint256[2] public live;
    uint256[2] public openedEver;
    uint256[2] public flipsEver;
    uint256[2] public kingEver;
    uint256[2] public challengerEver;
    uint256[4] public depositedBy;
    uint256[4] public claimedBy;
    mapping(uint256 => Round) internal rounds;
    uint256 public count;
    uint256 public totalDeposited;
    uint256 public totalClaimed;
    uint256 public totalTreasuryPaid;
    uint256 public treasuryDue;
    uint256 public successfulStakes;
    uint256 public successfulFinalizations;
    uint256 public successfulClaims;
    uint256 public rejectedCalls;
    uint256 internal immutable treasuryInitialBalance;

    constructor(CrownRegistry registry_, address token, address rival) {
        registry = registry_;
        tokens = [token, rival];
        tickers = [keccak256("CRWN"), keccak256("SECOND")];
        for (uint256 i; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("registry-model-actor-", bytes1(uint8(65 + i)))));
            vm.deal(actors[i], 1_000 ether);
        }
        for (uint256 i; i < 2; i++) {
            expectedKing[i] = token;
            expectedBeneficiary[i] = actors[i];
            expectedReign[i] = uint64(block.timestamp);
            registry.registerKing(tickers[i], token, actors[i]);
        }
        treasuryInitialBalance = registry.TREASURY().balance;
    }

    function open(uint256 tickerSeed, uint256 actorSeed) public {
        uint256 t = tickerSeed % 2;
        uint256 a = actorSeed % 4;
        address candidate = expectedKing[t] == tokens[0] ? tokens[1] : tokens[0];
        bytes memory reason;
        if (live[t] != 0 && block.timestamp < rounds[live[t]].opened + 72 hours) {
            // A live challenge in its window can only be displaced with twice its bond (never done here).
            reason = abi.encodeWithSelector(CrownRegistry.WrongBond.selector, 0.01 ether, 0.02 ether);
        } else if (live[t] != 0) {
            reason = abi.encodeWithSelector(CrownRegistry.ChallengeLive.selector, tickers[t], live[t]);
        } else if (block.timestamp < expectedReign[t] + 7 days) {
            reason = abi.encodeWithSelector(CrownRegistry.ReignTooYoung.selector, uint64(expectedReign[t] + 7 days));
        } else if (block.timestamp < expectedCooldown[t]) {
            reason = abi.encodeWithSelector(CrownRegistry.InCooldown.selector, expectedCooldown[t]);
        }
        if (reason.length != 0) {
            vm.prank(actors[a]);
            vm.expectRevert(reason);
            registry.openChallenge{value: 0.01 ether}(tickers[t], candidate);
            rejectedCalls++;
            return;
        }
        vm.prank(actors[a]);
        uint256 id = registry.openChallenge{value: 0.01 ether}(tickers[t], candidate);
        assertEq(id, ++count);
        Round storage r = rounds[id];
        r.tickerIndex = t;
        r.opened = uint64(block.timestamp);
        r.candidate = candidate;
        r.beneficiary = actors[a];
        r.challengerTotal = 0.01 ether;
        r.challengers[a] = 0.01 ether;
        live[t] = id;
        openedEver[t]++;
        challengerEver[t] += 0.01 ether;
        depositedBy[a] += 0.01 ether;
        totalDeposited += 0.01 ether;
    }

    function stake(uint256 tickerSeed, uint256 actorSeed, bool kingSide, uint96 amountSeed) public {
        uint256 t = tickerSeed % 2;
        uint256 a = actorSeed % 4;
        uint256 id = live[t] == 0 ? count + 1 : live[t];
        uint256 amount = bound(amountSeed, 0, 0.1 ether);
        CrownRegistry.Side side = kingSide ? CrownRegistry.Side.King : CrownRegistry.Side.Challenger;
        bytes memory reason;
        if (id > count) {
            reason = abi.encodeWithSelector(CrownRegistry.UnknownChallenge.selector, id);
        } else if (amount == 0) {
            reason = abi.encodeWithSelector(CrownRegistry.ZeroStake.selector);
        } else if (block.timestamp >= rounds[id].opened + 72 hours) {
            reason = abi.encodeWithSelector(CrownRegistry.WindowClosed.selector, uint64(rounds[id].opened + 72 hours));
        }
        if (reason.length != 0) {
            vm.prank(actors[a]);
            vm.expectRevert(reason);
            registry.stake{value: amount}(id, side);
            rejectedCalls++;
            return;
        }
        vm.prank(actors[a]);
        registry.stake{value: amount}(id, side);
        Round storage r = rounds[id];
        if (kingSide) {
            r.kings[a] += amount;
            r.kingTotal += amount;
            kingEver[t] += amount;
        } else {
            r.challengers[a] += amount;
            r.challengerTotal += amount;
            challengerEver[t] += amount;
        }
        depositedBy[a] += amount;
        totalDeposited += amount;
        successfulStakes++;
    }

    function advance(uint32 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 8 days));
    }

    /// @dev Visit one second either side of every deadline, without moving time backwards.
    function advanceToBoundary(uint256 tickerSeed, uint8 boundarySeed) public {
        uint256 t = tickerSeed % 2;
        uint256 id = live[t];
        uint256 boundary;
        if (id != 0 && boundarySeed % 3 != 0) {
            boundary = rounds[id].opened + (boundarySeed % 3 == 1 ? 72 hours : 96 hours);
        } else {
            boundary = expectedReign[t] + 7 days;
            if (expectedCooldown[t] > boundary) boundary = expectedCooldown[t];
        }
        boundary = boundary - 1 + (boundarySeed / 3) % 3;
        if (boundary > block.timestamp) vm.warp(boundary);
    }

    function finalize(uint256 idSeed) public {
        uint256 id = 1 + idSeed % (count + 1);
        _finalize(id);
    }

    function _finalize(uint256 id) internal {
        Round storage r = rounds[id];
        if (id > count) {
            vm.expectRevert(abi.encodeWithSelector(CrownRegistry.UnknownChallenge.selector, id));
            registry.finalize(id);
            rejectedCalls++;
            return;
        }
        if (r.done) {
            vm.expectRevert(abi.encodeWithSelector(CrownRegistry.AlreadyFinalized.selector, id));
            registry.finalize(id);
            rejectedCalls++;
            return;
        }
        if (block.timestamp < r.opened + 96 hours) {
            vm.expectRevert(abi.encodeWithSelector(CrownRegistry.TooEarly.selector, uint64(r.opened + 96 hours)));
            registry.finalize(id);
            rejectedCalls++;
            return;
        }
        registry.finalize(id);
        r.done = true;
        r.won = r.challengerTotal > r.kingTotal && r.challengerTotal + r.kingTotal >= 0.05 ether;
        uint256 losing = r.won ? r.kingTotal : r.challengerTotal;
        uint256 winning = r.won ? r.challengerTotal : r.kingTotal;
        uint256 slash = losing / 5;
        treasuryDue += winning == 0 ? slash : slash - slash / 2;
        uint256 t = r.tickerIndex;
        live[t] = 0;
        if (r.won) {
            expectedKing[t] = r.candidate;
            expectedBeneficiary[t] = r.beneficiary;
            expectedReign[t] = uint64(block.timestamp);
            flipsEver[t]++;
        } else {
            expectedCooldown[t] = uint64(block.timestamp + 3 days);
        }
        successfulFinalizations++;
    }

    function claim(uint256 idSeed, uint256 actorSeed) public {
        _claim(1 + idSeed % (count + 1), actorSeed % 4);
    }

    function _claim(uint256 id, uint256 a) internal {
        Round storage r = rounds[id];
        uint256 expected = _entitlement(r, a);
        bytes memory reason;
        if (id > count) reason = abi.encodeWithSelector(CrownRegistry.UnknownChallenge.selector, id);
        else if (!r.done) reason = abi.encodeWithSelector(CrownRegistry.NotFinalized.selector, id);
        else if (r.pulled[a] || expected == 0) reason = abi.encodeWithSelector(CrownRegistry.NothingToClaim.selector);
        if (reason.length != 0) {
            vm.prank(actors[a]);
            vm.expectRevert(reason);
            registry.claim(id);
            rejectedCalls++;
            return;
        }
        uint256 before = actors[a].balance;
        vm.prank(actors[a]);
        registry.claim(id);
        assertEq(actors[a].balance - before, expected);
        r.pulled[a] = true;
        totalClaimed += expected;
        claimedBy[a] += expected;
        successfulClaims++;
    }

    function withdrawTreasury() public {
        if (treasuryDue == 0) {
            vm.expectRevert(CrownRegistry.NothingToClaim.selector);
            registry.withdrawTreasury();
            rejectedCalls++;
            return;
        }
        registry.withdrawTreasury();
        totalTreasuryPaid += treasuryDue;
        treasuryDue = 0;
    }

    function _entitlement(Round storage r, uint256 a) internal view returns (uint256) {
        if (!r.done) return 0;
        uint256 win = r.won ? r.challengers[a] : r.kings[a];
        uint256 lose = r.won ? r.kings[a] : r.challengers[a];
        uint256 winTotal = r.won ? r.challengerTotal : r.kingTotal;
        uint256 losingTotal = r.won ? r.kingTotal : r.challengerTotal;
        uint256 bonus = (losingTotal / 5) / 2;
        return lose * 4 / 5 + win + (win == 0 ? 0 : win * bonus / winTotal);
    }

    function assertAccounting() external view {
        assertEq(address(registry).balance, totalDeposited - totalClaimed - totalTreasuryPaid);
        assertEq(registry.treasuryOwed(), treasuryDue);
        assertEq(registry.TREASURY().balance, treasuryInitialBalance + totalTreasuryPaid);
        uint256 liabilities = treasuryDue;
        uint256 dust;
        for (uint256 id = 1; id <= count; id++) {
            Round storage r = rounds[id];
            if (!r.done) {
                liabilities += r.kingTotal + r.challengerTotal;
            } else {
                uint256 entitlements;
                for (uint256 a; a < 4; a++) {
                    uint256 entitlement = _entitlement(r, a);
                    entitlements += entitlement;
                    if (!r.pulled[a]) liabilities += entitlement;
                    assertEq(registry.claimable(id, actors[a]), r.pulled[a] ? 0 : entitlement);
                    assertEq(registry.claimed(id, actors[a]), r.pulled[a]);
                }
                uint256 losing = r.won ? r.kingTotal : r.challengerTotal;
                uint256 winning = r.won ? r.challengerTotal : r.kingTotal;
                uint256 treasury = winning == 0 ? losing / 5 : losing / 5 - (losing / 5) / 2;
                uint256 roundDust = r.kingTotal + r.challengerTotal - entitlements - treasury;
                assertLt(roundDust, 8, "dust bounded by four wallets on two sides");
                dust += roundDust;
            }
        }
        assertEq(address(registry).balance, liabilities + dust, "escrow equals outstanding obligations plus dust");
        for (uint256 a; a < 4; a++) {
            assertEq(actors[a].balance, 1_000 ether + claimedBy[a] - depositedBy[a]);
        }
    }

    function assertState() external view {
        assertEq(registry.challengeCount(), count);
        for (uint256 t; t < 2; t++) {
            ICrownRegistry.King memory k = registry.king(tickers[t]);
            assertEq(k.token, expectedKing[t]);
            assertEq(k.beneficiary, expectedBeneficiary[t]);
            assertEq(k.reignStartedAt, expectedReign[t]);
            assertEq(registry.cooldownUntil(tickers[t]), expectedCooldown[t]);
            assertEq(registry.liveChallenge(tickers[t]), live[t]);
            assertEq(registry.hasLiveChallenge(tickers[t]), live[t] != 0);
            (uint256 opened, uint256 flips, uint256 kingSum, uint256 challengerSum) = registry.tickerTotals(tickers[t]);
            assertEq(opened, openedEver[t]);
            assertEq(flips, flipsEver[t]);
            assertEq(kingSum, kingEver[t]);
            assertEq(challengerSum, challengerEver[t]);
        }
        for (uint256 id = 1; id <= count; id++) {
            Round storage r = rounds[id];
            CrownRegistry.Challenge memory c = registry.challenges(id);
            assertEq(c.ticker, tickers[r.tickerIndex]);
            assertEq(c.challengerToken, r.candidate);
            assertEq(c.challengerBeneficiary, r.beneficiary);
            assertEq(c.openedAt, r.opened);
            assertEq(c.windowEnd, r.opened + 72 hours);
            assertEq(c.finalizeAfter, r.opened + 96 hours);
            assertEq(c.kingStake, r.kingTotal);
            assertEq(c.challengerStake, r.challengerTotal);
            assertEq(c.finalized, r.done);
            assertEq(c.challengerWon, r.won);
            uint256 losing = r.won ? r.kingTotal : r.challengerTotal;
            uint256 winning = r.won ? r.challengerTotal : r.kingTotal;
            assertEq(c.winnerBonus, r.done && winning != 0 ? (losing / 5) / 2 : 0);
            for (uint256 a; a < 4; a++) {
                assertEq(registry.kingStakeOf(id, actors[a]), r.kings[a]);
                assertEq(registry.challengerStakeOf(id, actors[a]), r.challengers[a]);
            }
        }
    }

    /// @dev End every sequence by proving that all mature obligations can actually be withdrawn.
    /// This is excluded from the random selectors and called only by afterInvariant().
    function drain() external {
        vm.warp(vm.getBlockTimestamp() + 4 days);
        for (uint256 id = 1; id <= count; id++) {
            if (!rounds[id].done) _finalize(id);
            for (uint256 a; a < 4; a++) {
                if (!rounds[id].pulled[a] && _entitlement(rounds[id], a) != 0) _claim(id, a);
            }
        }
        if (treasuryDue != 0) withdrawTreasury();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CrownRegistryInvariantTest is Test {
    CrownRegistryHandler handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        CrownRegistry registry = new CrownRegistry("", address(0), address(0));
        CrownToken token = new CrownToken();
        CrownChallengerToken rival = new CrownChallengerToken(address(this));
        handler = new CrownRegistryHandler(registry, address(token), address(rival));
        handler.advance(7 days);
        // Both tickers begin with live challenges, including a dual-side staker.
        handler.open(0, 0);
        handler.stake(0, 1, true, 0.02 ether);
        handler.stake(0, 1, false, 0.04 ether);
        handler.open(1, 2);
        handler.stake(1, 3, true, 0.05 ether);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.stake.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.advanceToBoundary.selector;
        selectors[4] = handler.finalize.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.withdrawTreasury.selector;
        // Weight stakes twice to exercise aggregation before deadlines as well as invalid calls.
        selectors[7] = handler.stake.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_escrowEqualsOutstandingLiabilitiesPlusBoundedDust() public view {
        handler.assertAccounting();
    }

    function invariant_ruleBasedResolutionAndImmutableFinishedRounds() public view {
        handler.assertState();
    }

    function afterInvariant() public {
        handler.drain();
        handler.assertAccounting();
        handler.assertState();
        assertGe(handler.successfulFinalizations(), 2);
        assertGe(handler.successfulClaims(), 4);
    }
}
