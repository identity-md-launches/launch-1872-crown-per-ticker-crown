// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CrownHook} from "src/CrownHook.sol";
import {CrownRegistry} from "src/CrownRegistry.sol";
import {CrownToken} from "src/CrownToken.sol";
import {CrownChallengerToken} from "src/CrownChallengerToken.sol";
import {HookDeployer} from "../utils/HookDeployer.sol";
import {Swapper} from "../mocks/Swapper.sol";
import {LiquidityProvider} from "../mocks/LiquidityProvider.sol";

/// @dev Random full fills and price-limited partial fills in all four swap shapes, interspersed with
/// successful and failed challenges.
contract CrownHookHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    bytes32 constant TICKER = keccak256("CRWN");
    Currency constant ETH = Currency.wrap(address(0));
    CrownRegistry public immutable registry;
    CrownHook public immutable hook;
    CrownToken public immutable token;
    CrownChallengerToken public immutable rival;
    Swapper public immutable swapper;
    PoolKey internal key;
    address[2] public wallets;
    address public immutable voter;
    address public expectedToken;
    uint256 public currentWallet;
    uint256 public totalPaid;
    uint256[2] public paidTo;
    uint256[2] public bonded;
    uint256[2] public refunded;
    uint256 public registryDeposits;
    uint256 public registryClaims;
    uint256 public treasuryPaid;
    uint256 public swaps;
    uint256 public partialSwaps;
    uint256 public flips;
    uint256 public failedChallenges;

    constructor(
        CrownRegistry r,
        CrownHook h,
        CrownToken t,
        CrownChallengerToken rival_,
        Swapper s,
        PoolKey memory k,
        address kingWallet,
        address challengerWallet
    ) {
        registry = r;
        hook = h;
        token = t;
        rival = rival_;
        swapper = s;
        key = k;
        wallets = [kingWallet, challengerWallet];
        expectedToken = address(t);
        voter = makeAddr("hook-invariant-voter");
        vm.deal(voter, 100 ether);
    }

    function buy(uint96 amountSeed, bool exactOutput) public {
        _swap(true, exactOutput, amountSeed);
    }

    function sell(uint96 amountSeed, bool exactOutput) public {
        _swap(false, exactOutput, amountSeed);
    }

    function _swap(bool buy_, bool exactOutput, uint96 amountSeed) internal {
        // Full-range liquidity and small orders keep these calls in the full-fill domain (limited
        // fills are `_swapLimited`). Across 96 calls neither side can consume the router's funding.
        uint256 amount = bound(amountSeed, 1e9, 1 ether);
        uint256[2] memory before = [wallets[0].balance, wallets[1].balance];
        uint256 ethBefore = address(swapper).balance;
        uint256 tokenBefore = token.balanceOf(address(swapper));
        uint256 managerBefore = address(hook.poolManager()).balance;
        BalanceDelta d = exactOutput ? swapper.swapExact(key, buy_, int256(amount)) : swapper.swap(key, buy_, amount);
        uint256 fee = wallets[currentWallet].balance - before[currentWallet];
        assertEq(wallets[1 - currentWallet].balance, before[1 - currentWallet], "only current beneficiary is paid");
        if (buy_) {
            assertLt(d.amount0(), 0);
            assertGt(d.amount1(), 0);
            assertEq(ethBefore - address(swapper).balance, _abs(d.amount0()));
            assertEq(token.balanceOf(address(swapper)) - tokenBefore, _abs(d.amount1()));
            assertEq(address(hook.poolManager()).balance + fee, managerBefore + _abs(d.amount0()));
        } else {
            assertGt(d.amount0(), 0);
            assertLt(d.amount1(), 0);
            assertEq(address(swapper).balance - ethBefore, _abs(d.amount0()));
            assertEq(tokenBefore - token.balanceOf(address(swapper)), _abs(d.amount1()));
            assertEq(address(hook.poolManager()).balance + fee + _abs(d.amount0()), managerBefore);
        }
        uint256 specified = buy_ == exactOutput ? _abs(d.amount1()) : _abs(d.amount0());
        assertEq(specified, amount, "order filled completely");
        uint256 rawEth = buy_ ? _abs(d.amount0()) - fee : _abs(d.amount0()) + fee;
        assertEq(fee, buy_ != exactOutput ? amount / 100 : rawEth / 100);
        assertGt(fee, 0);
        totalPaid += fee;
        paidTo[currentWallet] += fee;
        swaps++;
    }

    function buyLimited(uint96 amountSeed, uint16 limitSeed, bool exactOutput) public {
        _swapLimited(true, exactOutput, amountSeed, limitSeed);
    }

    function sellLimited(uint96 amountSeed, uint16 limitSeed, bool exactOutput) public {
        _swapLimited(false, exactOutput, amountSeed, limitSeed);
    }

    /// @dev A price limit a few bps away from the current price: most orders stop short of it. On a
    /// full fill of an ETH-specified order the cut is bps of the order; on anything else it is bps of
    /// the ETH the pool actually moved. The beneficiary is paid exactly that, and nobody else.
    function _swapLimited(bool buy_, bool exactOutput, uint96 amountSeed, uint16 limitSeed) internal {
        uint256 amount = bound(amountSeed, 1e9, 1 ether);
        uint256[4] memory before = _balances();
        BalanceDelta d = swapper.swapWithLimit(
            key, buy_, exactOutput ? int256(amount) : -int256(amount), _limitFor(buy_, bound(limitSeed, 1, 300))
        );
        uint256 fee = _checkSettlement(buy_, d, before);
        uint256 userEth = _abs(d.amount0());
        uint256 poolEth = buy_ ? userEth - fee : userEth + fee;
        bool ethSpecified = buy_ != exactOutput;
        bool fullFill = ethSpecified ? userEth == amount : _abs(d.amount1()) == amount;
        if (ethSpecified && fullFill) assertEq(fee, amount / 100, "full fill: 1% of the order");
        else assertEq(fee, poolEth / 100, "1% of the ETH the pool moved");
        if (!fullFill) partialSwaps++;
        totalPaid += fee;
        paidTo[currentWallet] += fee;
        swaps++;
    }

    function _limitFor(bool buy_, uint256 limitBps) internal view returns (uint160) {
        (uint160 price,,,) = hook.poolManager().getSlot0(key.toId());
        return buy_
            ? uint160(uint256(price) * (10_000 - limitBps) / 10_000)
            : uint160(uint256(price) * (10_000 + limitBps) / 10_000);
    }

    /// @dev [king wallet, challenger wallet, router ETH, router tokens] plus the manager's ETH in slot 4.
    function _balances() internal view returns (uint256[4] memory b) {
        b[0] = wallets[0].balance;
        b[1] = wallets[1].balance;
        b[2] = address(swapper).balance + (address(hook.poolManager()).balance << 128);
        b[3] = token.balanceOf(address(swapper));
    }

    /// @dev The swapper moved exactly its delta, the manager's ETH changed by the delta minus the fee,
    /// and only the current beneficiary was paid. Returns the fee.
    function _checkSettlement(bool buy_, BalanceDelta d, uint256[4] memory before) internal view returns (uint256 fee) {
        fee = wallets[currentWallet].balance - before[currentWallet];
        assertEq(wallets[1 - currentWallet].balance, before[1 - currentWallet], "only current beneficiary is paid");
        uint256 userEth = _abs(d.amount0());
        uint256 routerBefore = uint128(before[2]);
        uint256 managerBefore = before[2] >> 128;
        uint256 managerNow = address(hook.poolManager()).balance;
        if (buy_) {
            assertEq(routerBefore - address(swapper).balance, userEth);
            assertEq(token.balanceOf(address(swapper)) - before[3], _abs(d.amount1()));
            assertEq(managerNow + fee, managerBefore + userEth);
        } else {
            assertEq(address(swapper).balance - routerBefore, userEth);
            assertEq(before[3] - token.balanceOf(address(swapper)), _abs(d.amount1()));
            assertEq(managerNow + fee + userEth, managerBefore);
        }
    }

    function resolveChallenge(bool challengerWins, uint96 stakeSeed) public {
        uint256 nextWallet = 1 - currentWallet;
        address candidate = expectedToken == address(token) ? address(rival) : address(token);
        uint256 start = registry.king(TICKER).reignStartedAt + 7 days;
        if (registry.cooldownUntil(TICKER) > start) start = registry.cooldownUntil(TICKER);
        if (vm.getBlockTimestamp() < start) vm.warp(start);
        vm.prank(wallets[nextWallet]);
        uint256 id = registry.openChallenge{value: 0.01 ether}(TICKER, candidate);
        bonded[nextWallet] += 0.01 ether;
        uint256 support = bound(stakeSeed, 0.05 ether, 0.1 ether);
        vm.prank(voter);
        registry.stake{value: support}(id, challengerWins ? CrownRegistry.Side.Challenger : CrownRegistry.Side.King);
        registryDeposits += support + 0.01 ether;
        vm.warp(vm.getBlockTimestamp() + 96 hours);
        registry.finalize(id);
        assertEq(registry.challenges(id).challengerWon, challengerWins);
        if (challengerWins) {
            currentWallet = nextWallet;
            expectedToken = candidate;
            flips++;
        } else {
            failedChallenges++;
        }

        uint256 refund = registry.claimable(id, wallets[nextWallet]);
        uint256 before = wallets[nextWallet].balance;
        vm.prank(wallets[nextWallet]);
        registry.claim(id);
        assertEq(wallets[nextWallet].balance - before, refund);
        refunded[nextWallet] += refund;
        registryClaims += refund;
        uint256 voterRefund = registry.claimable(id, voter);
        before = voter.balance;
        vm.prank(voter);
        registry.claim(id);
        assertEq(voter.balance - before, voterRefund);
        registryClaims += voterRefund;
        uint256 due = registry.treasuryOwed();
        if (due != 0) {
            before = registry.TREASURY().balance;
            registry.withdrawTreasury();
            assertEq(registry.TREASURY().balance - before, due);
            treasuryPaid += due;
        }
    }

    function assertPaymentAccounting() external view {
        assertEq(hook.crownPaid(TICKER, ETH), totalPaid);
        assertEq(totalPaid, paidTo[0] + paidTo[1]);
        assertEq(hook.crownPaid(TICKER, key.currency1), 0);
        for (uint256 i; i < 2; i++) {
            assertEq(wallets[i].balance, 10 ether + paidTo[i] + refunded[i] - bonded[i]);
        }
        assertEq(registry.king(TICKER).token, expectedToken);
        assertEq(registry.king(TICKER).beneficiary, wallets[currentWallet]);
        assertEq(address(registry).balance, registryDeposits - registryClaims - treasuryPaid);
        assertEq(registry.treasuryOwed(), 0);
    }

    function _abs(int128 amount) internal pure returns (uint256) {
        return amount < 0 ? uint256(uint128(-amount)) : uint256(uint128(amount));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CrownHookInvariantTest is Test {
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    CrownHookHandler handler;
    CrownRegistry registry;
    CrownToken token;
    CrownChallengerToken rival;
    CrownHook hook;
    PoolManager manager;
    LiquidityProvider lp;
    Swapper swapper;
    PoolKey key;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_700_000_000);
        address first = makeAddr("hook-invariant-first-beneficiary");
        address second = makeAddr("hook-invariant-second-beneficiary");
        vm.deal(first, 10 ether);
        vm.deal(second, 10 ether);
        manager = new PoolManager(address(this));
        token = new CrownToken();
        rival = new CrownChallengerToken(address(this));
        registry = new CrownRegistry("CRWN", address(token), first);
        hook = HookDeployer.deploy(manager, address(this));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, 79228162514264337593543950336);
        hook.setRegistry(registry);
        hook.registerPool(key, keccak256("CRWN"), 100);
        lp = new LiquidityProvider(manager);
        swapper = new Swapper(manager);
        token.transfer(address(lp), 10_000 ether);
        vm.deal(address(lp), 10_000 ether);
        lp.modify(key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1_000e18);
        token.transfer(address(swapper), 1_000 ether);
        vm.deal(address(swapper), 1_000 ether);
        handler = new CrownHookHandler(registry, hook, token, rival, swapper, key, first, second);
        // Every run starts with an actual fee payment; random sequences exercise both recipients.
        handler.buy(1 ether, false);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.resolveChallenge.selector;
        selectors[3] = handler.buyLimited.selector;
        selectors[4] = handler.sellLimited.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_paidCounterMatchesTransfersAcrossReigns() public view {
        handler.assertPaymentAccounting();
    }

    function invariant_hookRetainsNoValueOrSettlementDebt() public view {
        IPoolManager m = IPoolManager(address(manager));
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(rival.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertFalse(m.isUnlocked());
        assertEq(m.getNonzeroDeltaCount(), 0);
        assertEq(m.currencyDelta(address(hook), key.currency0), 0);
        assertEq(m.currencyDelta(address(hook), key.currency1), 0);
        assertEq(address(hook.registry()), address(registry));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(rival.totalSupply(), 1_000_000_000 ether);
        assertEq(rival.balanceOf(address(this)), rival.totalSupply());
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(lp)) + token.balanceOf(address(swapper))
                + token.balanceOf(address(manager)),
            token.totalSupply()
        );
    }

    function afterInvariant() public {
        // Exercise both a retained crown and a flip even for an unlucky sequence with no challenges.
        handler.resolveChallenge(false, 0.05 ether);
        handler.resolveChallenge(true, 0.05 ether);
        handler.buy(1 ether, false);
        // A partial fill in every sequence, so the rehearsal path is always under the invariants.
        handler.buyLimited(1 ether, 1, false);
        handler.sellLimited(1 ether, 1, true);
        handler.assertPaymentAccounting();
        invariant_hookRetainsNoValueOrSettlementDebt();
        assertGt(handler.partialSwaps(), 0);
        assertGt(handler.flips(), 0);
        assertGt(handler.failedChallenges(), 0);
        assertGt(handler.swaps(), 1);
    }
}
