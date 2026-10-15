// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CrownHook} from "../src/CrownHook.sol";
import {CrownRegistry} from "../src/CrownRegistry.sol";
import {ICrownRegistry} from "../src/interfaces/ICrownRegistry.sol";
import {CrownToken} from "../src/CrownToken.sol";
import {CrownChallengerToken} from "../src/CrownChallengerToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {LiquidityProvider} from "./mocks/LiquidityProvider.sol";

/// @dev A registry stand-in whose read always reverts.
contract RevertingRegistry {
    function king(bytes32) external pure returns (ICrownRegistry.King memory) {
        revert("down");
    }
}

/// @dev A registry stand-in whose `king` answer is 96 bytes long but carries a bit above the address
/// in the beneficiary word, which `abi.decode` rejects.
contract DirtyRegistry {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            mstore(32, shl(160, 1))
            mstore(64, 0)
            return(0, 96)
        }
    }
}

/// @dev A beneficiary that refuses ETH.
contract EthRejecter {}

/// @dev Uses more than the hook's payout allowance; the caller must still finish its swap.
contract GasBurningBeneficiary {
    receive() external payable {
        assembly { for {} 1 {} {} }
    }
}

contract CrownHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant SPACING = 60;
    bytes32 constant CRWN = keccak256("CRWN");
    Currency constant ETH = Currency.wrap(address(0));

    address owner = makeAddr("owner");
    address kingWallet = makeAddr("kingWallet");
    address challenger = makeAddr("challenger");
    address alice = makeAddr("alice");

    PoolManager manager;
    CrownToken token;
    CrownRegistry registry;
    CrownHook hook;
    Swapper swapper;
    LiquidityProvider lp;
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_000_000);
        manager = new PoolManager(address(this));
        token = new CrownToken();
        registry = new CrownRegistry("CRWN", address(token), kingWallet);
        hook = HookDeployer.deploy(manager, owner);
        swapper = new Swapper(manager);
        lp = new LiquidityProvider(manager);
        key = PoolKey({
            currency0: ETH,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.startPrank(owner);
        hook.setRegistry(registry);
        hook.registerPool(key, CRWN, hook.DEFAULT_CUT_BPS());
        vm.stopPrank();

        vm.deal(address(lp), 10_000 ether);
        token.transfer(address(lp), 10_000 ether);
        vm.deal(address(swapper), 1_000 ether);
        token.transfer(address(swapper), 1_000 ether);
        vm.deal(challenger, 10 ether);
        vm.deal(alice, 10 ether);
        lp.modify(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
    }

    // ------------------------------------------------------------ helpers

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    // ------------------------------------------------------------ permissions & access

    function test_permissionsAndAddressAgree() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HookDeployer.CROWN_FLAGS);
        assertEq(HookDeployer.CROWN_FLAGS, 0x10CC);
        assertEq(hook.owner(), owner);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_callbacksRefuseNonManager() public {
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.expectRevert(CrownHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(CrownHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(CrownHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
    }

    function test_afterInitializeRecordsPoolFromAnySender() public {
        MockERC20 other = new MockERC20("O", "O", 1e24);
        PoolKey memory k2 = PoolKey(ETH, Currency.wrap(address(other)), POOL_FEE, SPACING, IHooks(address(hook)));
        vm.prank(makeAddr("factory"));
        manager.initialize(k2, SQRT_PRICE_1_1);
        (bool initialized, bytes32 ticker, uint16 bps) = hook.pools(k2.toId());
        assertTrue(initialized);
        assertEq(ticker, bytes32(0));
        assertEq(bps, 0);
    }

    function test_setRegistryOnceAndOwnerOnly() public {
        CrownHook fresh = HookDeployer.deploy(manager, owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.setRegistry(registry);
        vm.prank(owner);
        vm.expectRevert(CrownHook.ZeroAddress.selector);
        fresh.setRegistry(ICrownRegistry(address(0)));
        vm.prank(owner);
        vm.expectRevert(CrownHook.ZeroAddress.selector);
        fresh.setRegistry(ICrownRegistry(makeAddr("eoa")));
        vm.prank(owner);
        fresh.setRegistry(registry);
        vm.prank(owner);
        vm.expectRevert(CrownHook.RegistryAlreadySet.selector);
        fresh.setRegistry(registry);
    }

    function test_registerPoolFailurePaths() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.registerPool(key, CRWN, 100);

        vm.startPrank(owner);
        vm.expectRevert(CrownHook.PoolAlreadyRegistered.selector);
        hook.registerPool(key, CRWN, 100);

        PoolKey memory wrongHook = key;
        wrongHook.hooks = IHooks(address(0));
        vm.expectRevert(CrownHook.NotThisHook.selector);
        hook.registerPool(wrongHook, CRWN, 100);

        MockERC20 a = new MockERC20("A", "A", 1e24);
        MockERC20 b = new MockERC20("B", "B", 1e24);
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory erc20Key =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, SPACING, IHooks(address(hook)));
        manager.initialize(erc20Key, SQRT_PRICE_1_1);
        vm.expectRevert(CrownHook.NotNativePool.selector);
        hook.registerPool(erc20Key, CRWN, 100);

        PoolKey memory notInit = key;
        notInit.fee = 3_000;
        vm.expectRevert(CrownHook.PoolNotInitialized.selector);
        hook.registerPool(notInit, CRWN, 100);

        manager.initialize(notInit, SQRT_PRICE_1_1);
        vm.expectRevert(CrownHook.ZeroTicker.selector);
        hook.registerPool(notInit, bytes32(0), 100);
        vm.expectRevert(abi.encodeWithSelector(CrownHook.CutTooHigh.selector, 501, 500));
        hook.registerPool(notInit, CRWN, 501);
        hook.registerPool(notInit, CRWN, 500);
        (, bytes32 ticker, uint16 bps) = hook.pools(notInit.toId());
        assertEq(ticker, CRWN);
        assertEq(bps, 500);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ the cut, four swap shapes

    function test_exactInputBuyPaysCutFromEthInput() public {
        uint256 before = kingWallet.balance;
        uint256 tokensBefore = token.balanceOf(address(swapper));
        vm.expectEmit(true, true, true, true);
        emit CrownHook.CrownPaid(poolId, CRWN, kingWallet, 0.01 ether);
        BalanceDelta d = swapper.swap(key, true, 1 ether);
        assertEq(d.amount0(), -1 ether, "the swapper pays exactly its input");
        assertGt(token.balanceOf(address(swapper)) - tokensBefore, 0);
        assertEq(kingWallet.balance - before, 0.01 ether, "1% of 1 ETH to the king");
        assertEq(hook.crownPaid(CRWN, ETH), 0.01 ether);
        assertEq(hook.quoteCut(poolId, 1 ether), 0.01 ether);
    }

    function test_exactOutputBuyPaysCutOnEthInput() public {
        uint256 before = kingWallet.balance;
        BalanceDelta d = swapper.swapExact(key, true, 1e18);
        assertEq(d.amount1(), 1e18, "exact output honoured");
        uint256 cut = kingWallet.balance - before;
        uint256 paid = _abs(d.amount0());
        assertGt(cut, 0);
        assertEq(cut, ((paid - cut) * 100) / 10_000, "cut is 1% of what the pool received");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    function test_exactInputSellPaysCutFromEthOutput() public {
        uint256 before = kingWallet.balance;
        uint256 ethBefore = address(swapper).balance;
        BalanceDelta d = swapper.swap(key, false, 1e18);
        assertEq(d.amount1(), -1e18);
        uint256 cut = kingWallet.balance - before;
        uint256 received = address(swapper).balance - ethBefore;
        assertEq(received, _abs(d.amount0()));
        assertGt(cut, 0);
        assertEq(cut, ((received + cut) * 100) / 10_000, "cut is 1% of what the pool paid out");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    function test_exactOutputSellPaysCutOnTopOfEthOutput() public {
        uint256 before = kingWallet.balance;
        uint256 ethBefore = address(swapper).balance;
        BalanceDelta d = swapper.swapExact(key, false, 1 ether);
        assertEq(d.amount0(), 1 ether, "the swapper receives exactly what it asked");
        assertEq(address(swapper).balance - ethBefore, 1 ether);
        assertEq(kingWallet.balance - before, 0.01 ether, "1% of the specified ETH to the king");
        assertEq(hook.crownPaid(CRWN, ETH), 0.01 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_cutMatchesBpsOnExactInputBuy(uint256 amountIn, uint16 bps) public {
        amountIn = bound(amountIn, 1, 100 ether);
        bps = uint16(bound(bps, 0, 500));
        PoolKey memory k = key;
        k.fee = 3_000;
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.registerPool(k, CRWN, bps);
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        uint256 before = kingWallet.balance;
        BalanceDelta d = swapper.swap(k, true, amountIn);
        assertEq(_abs(d.amount0()), amountIn);
        assertEq(kingWallet.balance - before, (amountIn * bps) / 10_000);
        assertEq(hook.crownPaid(CRWN, ETH), (amountIn * bps) / 10_000);
    }

    // ------------------------------------------------------------ the cut follows the fill, not the order

    /// @dev A pool with no liquidity fills nothing, so an exact-input buy costs nothing and pays nothing.
    function test_emptyPoolChargesNothingForAnUnfilledOrder() public {
        PoolKey memory k = key;
        k.fee = 3_000;
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.registerPool(k, CRWN, 100);
        uint256 before = kingWallet.balance;
        BalanceDelta d = swapper.swap(k, true, 1 ether);
        assertEq(d.amount0(), 0, "nothing was taken from the buyer");
        assertEq(d.amount1(), 0, "nothing was bought");
        assertEq(kingWallet.balance, before, "no cut on zero volume");
        assertEq(hook.crownPaid(CRWN, ETH), 0);
    }

    /// @dev An exact-input buy stopped by its price limit pays the cut on the ETH the pool consumed.
    function test_priceLimitPartialBuyPaysCutOnExecutedInput() public {
        uint256 before = kingWallet.balance;
        uint256 tokensBefore = token.balanceOf(address(swapper));
        BalanceDelta d = swapper.swapWithLimit(key, true, -1 ether, uint160(uint256(SQRT_PRICE_1_1) * 9_999 / 10_000));
        uint256 spent = _abs(d.amount0());
        uint256 cut = kingWallet.balance - before;
        assertGt(token.balanceOf(address(swapper)) - tokensBefore, 0, "some tokens were bought");
        assertLt(spent, 0.2 ether, "the order was only partly filled");
        assertGt(cut, 0);
        assertEq(cut, ((spent - cut) * 100) / 10_000, "cut is 1% of what the pool received, not of the order");
        assertLe(cut, spent / 100);
        assertEq(hook.crownPaid(CRWN, ETH), cut);
        assertEq(address(swapper).balance, 1_000 ether - spent, "the buyer paid exactly the fill plus the cut");
    }

    /// @dev An exact-output sell stopped by its price limit pays the cut on the ETH the pool delivered,
    /// and the seller keeps the rest instead of owing the cut on ETH that never came.
    function test_priceLimitPartialSellPaysCutOnDeliveredOutput() public {
        uint256 before = kingWallet.balance;
        uint256 ethBefore = address(swapper).balance;
        BalanceDelta d = swapper.swapWithLimit(key, false, 1 ether, uint160(uint256(SQRT_PRICE_1_1) * 10_001 / 10_000));
        uint256 received = address(swapper).balance - ethBefore;
        uint256 cut = kingWallet.balance - before;
        assertGt(d.amount0(), 0, "the seller received ETH");
        assertEq(received, _abs(d.amount0()));
        assertLt(received, 0.2 ether, "the order was only partly filled");
        assertLt(d.amount1(), 0, "tokens were sold");
        assertGt(cut, 0);
        assertEq(cut, ((received + cut) * 100) / 10_000, "cut is 1% of what the pool paid out, not of the order");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    function test_simulateSwapRefusesEveryoneButTheHook() public {
        vm.expectRevert(CrownHook.NotSelf.selector);
        hook.simulateSwap(key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2));
    }

    /// @dev The afterSwap shapes (token specified) also pay on executed ETH only when a price limit
    /// stops the order short: exact-output buy and exact-input sell.
    function test_priceLimitPartialExactOutputBuyPaysCutOnExecutedInput() public {
        uint256 before = kingWallet.balance;
        BalanceDelta d = swapper.swapWithLimit(key, true, 1e18, uint160(uint256(SQRT_PRICE_1_1) * 9_999 / 10_000));
        uint256 spent = _abs(d.amount0());
        uint256 cut = kingWallet.balance - before;
        assertGt(d.amount1(), 0, "some tokens were bought");
        assertLt(d.amount1(), 1e18, "the order was only partly filled");
        assertGt(cut, 0);
        assertEq(cut, ((spent - cut) * 100) / 10_000, "cut is 1% of what the pool received");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    function test_priceLimitPartialExactInputSellPaysCutOnDeliveredOutput() public {
        uint256 before = kingWallet.balance;
        BalanceDelta d = swapper.swapWithLimit(key, false, -1e18, uint160(uint256(SQRT_PRICE_1_1) * 10_001 / 10_000));
        uint256 received = _abs(d.amount0());
        uint256 cut = kingWallet.balance - before;
        assertGt(_abs(d.amount1()), 0, "some tokens were sold");
        assertLt(_abs(d.amount1()), 1e18, "the order was only partly filled");
        assertGt(cut, 0);
        assertEq(cut, ((received + cut) * 100) / 10_000, "cut is 1% of what the pool paid out");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
    }

    /// @dev No liquidity, any shape: nothing moves and nothing is charged. An empty pool's price runs
    /// to the limit on each swap, so the directions alternate.
    function test_emptyPoolChargesNothingInAnyShape() public {
        PoolKey memory k = key;
        k.fee = 3_000;
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.registerPool(k, CRWN, 100);
        uint256 before = kingWallet.balance;
        assertEq(BalanceDelta.unwrap(swapper.swap(k, true, 1 ether)), 0);
        assertEq(BalanceDelta.unwrap(swapper.swap(k, false, 1e18)), 0);
        assertEq(BalanceDelta.unwrap(swapper.swapExact(k, true, 1e18)), 0);
        assertEq(BalanceDelta.unwrap(swapper.swapExact(k, false, 1 ether)), 0);
        assertEq(kingWallet.balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        _assertSettledWithoutCustody();
    }

    /// @dev The rehearsal must leave no trace: a 1 ETH buy on the hooked pool lands the pool exactly
    /// where a 0.99 ETH buy lands an identical pool without a hook (price, tick, output, LP fee growth),
    /// and an exact-output sell of 1 ETH matches a plain sell of 1.01 ETH.
    function test_rehearsalLeavesNoTraceOnThePool() public {
        PoolKey memory plain = key;
        plain.hooks = IHooks(address(0));
        manager.initialize(plain, SQRT_PRICE_1_1);
        lp.modify(plain, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        IPoolManager m = IPoolManager(address(manager));

        BalanceDelta a = swapper.swap(key, true, 1 ether);
        BalanceDelta b = swapper.swap(plain, true, 0.99 ether);
        (uint160 pa, int24 ta,,) = m.getSlot0(poolId);
        (uint160 pb, int24 tb,,) = m.getSlot0(plain.toId());
        assertEq(pa, pb, "price");
        assertEq(ta, tb, "tick");
        assertEq(a.amount1(), b.amount1(), "token output");
        (uint256 fa,) = m.getFeeGrowthGlobals(poolId);
        (uint256 fb,) = m.getFeeGrowthGlobals(plain.toId());
        assertEq(fa, fb, "LP fee growth in ETH");

        a = swapper.swapExact(key, false, 1 ether);
        b = swapper.swapExact(plain, false, 1.01 ether);
        (pa,,,) = m.getSlot0(poolId);
        (pb,,,) = m.getSlot0(plain.toId());
        assertEq(pa, pb, "price after the sell");
        assertEq(a.amount1(), b.amount1(), "tokens sold");
        assertEq(hook.crownPaid(CRWN, ETH), 0.02 ether);
        _assertSettledWithoutCustody();
    }

    /// @dev A rehearsal that runs out of gas yields no cut, so a swapper might try to starve it and
    /// still complete the trade. Whatever gas is forwarded, either the swap reverts or the cut is paid.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_noGasLimitLetsASwapThroughWithoutTheCut(uint256 gas) public {
        gas = bound(gas, 30_000, 600_000);
        uint256 before = kingWallet.balance;
        try swapper.swap{gas: gas}(key, true, 1 ether) returns (BalanceDelta d) {
            assertEq(d.amount0(), -1 ether);
            assertEq(kingWallet.balance - before, 0.01 ether, "a swap went through without the cut");
            assertEq(hook.crownPaid(CRWN, ETH), 0.01 ether);
        } catch {
            assertEq(kingWallet.balance, before);
            assertEq(hook.crownPaid(CRWN, ETH), 0);
        }
        _assertSettledWithoutCustody();
    }

    /// @dev Random price limits in all four shapes. On a full fill of an ETH-specified order the cut is
    /// bps of the order; otherwise it is bps of the ETH the pool moved. Either way it lies between bps
    /// of the user's ETH and bps of the pool's ETH, and never exceeds bps of the ETH the user put up.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_cutFollowsExecutedEthUnderAnyPriceLimit(uint256 amount, uint16 limitBps, uint8 shape) public {
        amount = bound(amount, 1e12, 50 ether);
        limitBps = uint16(bound(limitBps, 1, 2_000));
        shape %= 4;
        bool buy = shape < 2;
        bool exactOutput = shape % 2 == 1;
        uint160 limit = buy
            ? uint160(uint256(SQRT_PRICE_1_1) * (10_000 - limitBps) / 10_000)
            : uint160(uint256(SQRT_PRICE_1_1) * (10_000 + limitBps) / 10_000);
        uint256 before = kingWallet.balance;
        uint256 ethBefore = address(swapper).balance;
        BalanceDelta d = swapper.swapWithLimit(key, buy, exactOutput ? int256(amount) : -int256(amount), limit);
        uint256 cut = kingWallet.balance - before;
        uint256 userEth = _abs(d.amount0());
        uint256 poolEth = buy ? userEth - cut : userEth + cut;
        bool ethSpecified = buy != exactOutput;
        if (ethSpecified && userEth == amount) {
            assertEq(cut, amount / 100, "full fill: 1% of the specified ETH");
        } else {
            assertEq(cut, poolEth / 100, "partial fill or token-specified: 1% of the ETH the pool moved");
        }
        (uint256 lo, uint256 hi) = userEth < poolEth ? (userEth, poolEth) : (poolEth, userEth);
        assertGe(cut, lo / 100);
        assertLe(cut, hi / 100);
        if (buy) assertEq(ethBefore - address(swapper).balance, userEth, "buyer paid exactly the delta");
        else assertEq(address(swapper).balance - ethBefore, userEth, "seller received exactly the delta");
        assertEq(hook.crownPaid(CRWN, ETH), cut);
        _assertSettledWithoutCustody();
    }

    // ------------------------------------------------------------ never blocks a swap

    /// @dev A 96-byte answer with a dirty beneficiary word is malformed: the swap runs without the cut.
    function test_malformedRegistryAnswerNoCut() public {
        CrownHook h = HookDeployer.deploy(manager, owner);
        PoolKey memory k = PoolKey(ETH, Currency.wrap(address(token)), POOL_FEE, SPACING, IHooks(address(h)));
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        h.setRegistry(ICrownRegistry(address(new DirtyRegistry())));
        h.registerPool(k, CRWN, 100);
        vm.stopPrank();
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(k.toId(), CRWN, 0.01 ether, "REGISTRY_READ_FAILED");
        BalanceDelta d = swapper.swap(k, true, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        assertEq(h.crownPaid(CRWN, ETH), 0);
        // The sell direction (afterSwap path) proceeds as well.
        d = swapper.swap(k, false, 1e18);
        assertEq(d.amount1(), -1e18);
        assertEq(h.crownPaid(CRWN, ETH), 0);
    }

    function test_noRegistryNoCut() public {
        CrownHook bare = HookDeployer.deploy(manager, owner);
        PoolKey memory k = PoolKey(ETH, Currency.wrap(address(token)), POOL_FEE, SPACING, IHooks(address(bare)));
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(owner);
        bare.registerPool(k, CRWN, 100);
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        uint256 before = kingWallet.balance;
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(k.toId(), CRWN, 0.01 ether, "NO_REGISTRY");
        swapper.swap(k, true, 1 ether);
        assertEq(kingWallet.balance, before);
        assertEq(bare.crownPaid(CRWN, ETH), 0);
    }

    function test_unregisteredPoolNoCut() public {
        PoolKey memory k = key;
        k.fee = 3_000;
        manager.initialize(k, SQRT_PRICE_1_1);
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        uint256 before = kingWallet.balance;
        swapper.swap(k, true, 1 ether);
        swapper.swapExact(k, false, 1 ether);
        assertEq(kingWallet.balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
    }

    function test_registryReadFailureNoCut() public {
        CrownHook h = HookDeployer.deploy(manager, owner);
        PoolKey memory k = PoolKey(ETH, Currency.wrap(address(token)), POOL_FEE, SPACING, IHooks(address(h)));
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        h.setRegistry(ICrownRegistry(address(new RevertingRegistry())));
        h.registerPool(k, CRWN, 100);
        vm.stopPrank();
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(k.toId(), CRWN, 0.01 ether, "REGISTRY_READ_FAILED");
        BalanceDelta d = swapper.swap(k, true, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertEq(h.crownPaid(CRWN, ETH), 0);
    }

    /// @dev Every reply length skips the cut and lets both callbacks through. A 96-byte reply of zeros
    /// is well formed with no king (`NO_KING`); every other length is `REGISTRY_READ_FAILED`.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyLengthRegistryResponseSkipsBothCallbacks(uint8 lengthSeed) public {
        uint256 length = bound(lengthSeed, 0, 192);
        vm.mockCall(address(registry), abi.encodeCall(ICrownRegistry.king, (CRWN)), new bytes(length));
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(
            poolId, CRWN, 0.01 ether, length == 96 ? bytes32("NO_KING") : bytes32("REGISTRY_READ_FAILED")
        );
        uint256 before = kingWallet.balance;
        BalanceDelta d = swapper.swap(key, true, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        d = swapper.swap(key, false, 1e18);
        assertEq(d.amount1(), -1e18);
        assertGt(d.amount0(), 0);
        assertEq(kingWallet.balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        _assertSettledWithoutCustody();
    }

    function test_outOfGasBeneficiaryCannotBlockEitherCallback() public {
        GasBurningBeneficiary burner = new GasBurningBeneficiary();
        vm.mockCall(
            address(registry),
            abi.encodeCall(ICrownRegistry.king, (CRWN)),
            abi.encode(address(token), address(burner), uint64(1_000_000))
        );
        BalanceDelta d = swapper.swap(key, true, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        d = swapper.swap(key, false, 1e18);
        assertEq(d.amount1(), -1e18);
        assertGt(d.amount0(), 0);
        assertEq(address(burner).balance, 0);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        _assertSettledWithoutCustody();
    }

    function test_failedSettlementRollsBackAlreadyAttemptedPayout() public {
        uint256 before = kingWallet.balance;
        uint256 managerBefore = address(manager).balance;
        uint256 tokensBefore = token.balanceOf(address(swapper));
        vm.deal(address(swapper), 0);
        // The fee transfer happens inside manager.swap, before this router tries to settle input.
        // Insufficient router funding then reverts the entire unlock, including that transfer.
        vm.expectRevert();
        swapper.swap(key, true, 1 ether);
        assertEq(kingWallet.balance, before);
        assertEq(address(manager).balance, managerBefore);
        assertEq(token.balanceOf(address(swapper)), tokensBefore);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
        _assertSettledWithoutCustody();
    }

    function test_multiplePoolsAggregateOnlyTheirOwnTickerPayments() public {
        PoolKey memory sameTicker = key;
        sameTicker.fee = 3_000;
        manager.initialize(sameTicker, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.registerPool(sameTicker, CRWN, 500);
        lp.modify(sameTicker, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        bytes32 otherTicker = keccak256("OTHER");
        address otherWallet = makeAddr("other-ticker-beneficiary");
        registry.registerKing(otherTicker, address(token), otherWallet);
        PoolKey memory otherPool = key;
        otherPool.fee = 500;
        manager.initialize(otherPool, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.registerPool(otherPool, otherTicker, 200);
        lp.modify(otherPool, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        uint256 before = kingWallet.balance;
        swapper.swap(key, true, 1 ether);
        swapper.swap(sameTicker, true, 2 ether);
        swapper.swap(otherPool, true, 3 ether);
        assertEq(kingWallet.balance - before, 0.11 ether);
        assertEq(otherWallet.balance, 0.06 ether);
        assertEq(hook.crownPaid(CRWN, ETH), 0.11 ether);
        assertEq(hook.crownPaid(otherTicker, ETH), 0.06 ether);
        assertEq(hook.crownPaid(otherTicker, key.currency1), 0);
        _assertSettledWithoutCustody();
    }

    function test_unknownTickerNoCut() public {
        PoolKey memory k = key;
        k.fee = 3_000;
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.registerPool(k, keccak256("NOKING"), 100);
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(k.toId(), keccak256("NOKING"), 0.01 ether, "NO_KING");
        swapper.swap(k, true, 1 ether);
        assertEq(hook.crownPaid(keccak256("NOKING"), ETH), 0);
    }

    function test_beneficiaryRejectingEthNoCut() public {
        EthRejecter rejecter = new EthRejecter();
        CrownRegistry r = new CrownRegistry("CRWN", address(token), address(rejecter));
        CrownHook h = HookDeployer.deploy(manager, owner);
        PoolKey memory k = PoolKey(ETH, Currency.wrap(address(token)), POOL_FEE, SPACING, IHooks(address(h)));
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        h.setRegistry(r);
        h.registerPool(k, CRWN, 100);
        vm.stopPrank();
        lp.modify(k, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1_000e18);
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(k.toId(), CRWN, 0.01 ether, "BENEFICIARY_REJECTED");
        BalanceDelta d = swapper.swap(k, true, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertEq(address(rejecter).balance, 0);
        assertEq(h.crownPaid(CRWN, ETH), 0);
        // The sell direction (afterSwap path) proceeds as well.
        d = swapper.swap(k, false, 1e18);
        assertEq(d.amount1(), -1e18);
        assertEq(h.crownPaid(CRWN, ETH), 0);
    }

    /// @dev A fresh PoolManager seeded with tokens only holds no ETH: the first buy pays no cut and
    /// still succeeds; the ETH it settles funds the cut of the next one.
    function test_freshManagerSeededWithTokensOnly() public {
        PoolManager fresh = new PoolManager(address(this));
        CrownHook h = HookDeployer.deploy(fresh, owner);
        PoolKey memory k = PoolKey(ETH, Currency.wrap(address(token)), POOL_FEE, SPACING, IHooks(address(h)));
        fresh.initialize(k, SQRT_PRICE_1_1);
        vm.startPrank(owner);
        h.setRegistry(registry);
        h.registerPool(k, CRWN, 100);
        vm.stopPrank();
        LiquidityProvider lp2 = new LiquidityProvider(fresh);
        token.transfer(address(lp2), 10_000 ether);
        // A range entirely below the current tick holds only currency1 (the token).
        lp2.modify(k, -600, -60, 1_000e18);
        assertEq(address(fresh).balance, 0);
        Swapper s2 = new Swapper(fresh);
        vm.deal(address(s2), 10 ether);

        uint256 before = kingWallet.balance;
        vm.expectEmit(true, true, false, true);
        emit CrownHook.CutSkipped(k.toId(), CRWN, 0.01 ether, "MANAGER_SHORT_OF_ETH");
        BalanceDelta d = s2.swap(k, true, 1 ether);
        assertEq(d.amount0(), -1 ether, "the first buy went through without the cut");
        assertGt(d.amount1(), 0);
        assertEq(kingWallet.balance, before);
        assertEq(address(fresh).balance, 1 ether);

        d = s2.swap(k, true, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertEq(kingWallet.balance - before, 0.01 ether, "the second buy pays");
        assertEq(h.crownPaid(CRWN, ETH), 0.01 ether);
    }

    function test_tinySwapRoundsCutToZero() public {
        uint256 before = kingWallet.balance;
        swapper.swap(key, true, 99);
        assertEq(kingWallet.balance, before);
        assertEq(hook.crownPaid(CRWN, ETH), 0);
    }

    // ------------------------------------------------------------ end to end: buy, challenge, stake, finalize, buy

    function test_endToEndDethroneChangesFeeRecipient() public {
        bytes20 registryBefore = bytes20(address(hook.registry()));
        bytes20 poolTokenBefore = bytes20(Currency.unwrap(key.currency1));
        bytes32 poolBefore = PoolId.unwrap(poolId);
        bytes32 tokenCodeBefore = address(token).codehash;
        uint256 kingBefore = kingWallet.balance;
        uint256 chalBefore = challenger.balance;

        // 1. Buy: the cut goes to the genesis king's wallet.
        swapper.swap(key, true, 2 ether);
        assertEq(kingWallet.balance - kingBefore, 0.02 ether);
        assertEq(hook.crownPaid(CRWN, ETH), 0.02 ether);

        // 2. Challenge with the standing challenger token once the reign is old enough.
        CrownChallengerToken rival = new CrownChallengerToken(challenger);
        assertTrue(address(rival) != address(token), "two distinct CRWN token deployments");
        assertEq(rival.name(), token.name());
        assertEq(rival.symbol(), token.symbol());
        vm.warp(block.timestamp + registry.MIN_REIGN());
        vm.prank(challenger);
        uint256 id = registry.openChallenge{value: 0.01 ether}(CRWN, address(rival));
        chalBefore -= 0.01 ether;

        // 3. Stake: king side 0.03, challenger side 0.01 + 0.05.
        vm.prank(alice);
        registry.stake{value: 0.03 ether}(id, CrownRegistry.Side.King);
        vm.prank(challenger);
        registry.stake{value: 0.05 ether}(id, CrownRegistry.Side.Challenger);
        chalBefore -= 0.05 ether;

        // A buy during the live challenge still pays the sitting king.
        swapper.swap(key, true, 1 ether);
        assertEq(kingWallet.balance - kingBefore, 0.03 ether);

        // Closing the vote does not bypass the additional 24-hour timelock.
        uint64 finalizeAfter = registry.challenges(id).finalizeAfter;
        vm.warp(finalizeAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.TooEarly.selector, finalizeAfter));
        registry.finalize(id);
        swapper.swap(key, true, 1 ether);
        assertEq(kingWallet.balance - kingBefore, 0.04 ether);
        assertEq(registry.king(CRWN).token, address(token));

        // 4. Finalize after window + timelock: the crown flips.
        vm.warp(registry.challenges(id).finalizeAfter);
        registry.finalize(id);
        ICrownRegistry.King memory k = registry.king(CRWN);
        assertEq(k.token, address(rival));
        assertEq(k.beneficiary, challenger);
        // Dethroning updates the king record; it does not replace either deployed contract or pool.
        assertEq(abi.encodePacked(bytes20(address(hook.registry()))), abi.encodePacked(registryBefore));
        assertEq(abi.encodePacked(bytes20(Currency.unwrap(key.currency1))), abi.encodePacked(poolTokenBefore));
        assertEq(PoolId.unwrap(key.toId()), poolBefore);
        assertEq(address(token).codehash, tokenCodeBefore);
        assertEq(token.totalSupply(), token.SUPPLY());
        assertEq(hook.crownPaid(CRWN, ETH), 0.04 ether, "finalize transfers no swap fees");
        vm.expectRevert(abi.encodeWithSelector(CrownRegistry.AlreadyFinalized.selector, id));
        registry.finalize(id);

        // 5. Buy and sell: every cut now goes to the challenger; the old king gets nothing more.
        swapper.swap(key, true, 1 ether);
        assertEq(challenger.balance - chalBefore, 0.01 ether, "the new king is paid");
        assertEq(kingWallet.balance - kingBefore, 0.04 ether, "the old king is not");
        uint256 sellBefore = challenger.balance;
        swapper.swap(key, false, 1e18);
        uint256 sellCut = challenger.balance - sellBefore;
        assertGt(sellCut, 0);

        // crownPaid matches every transfer made.
        assertEq(hook.crownPaid(CRWN, ETH), 0.04 ether + 0.01 ether + sellCut);
        assertEq(hook.crownPaid(CRWN, ETH), (kingWallet.balance - kingBefore) + (challenger.balance - chalBefore));

        // Stakers pull their money: alice lost 20% of 0.03; challenger gets stake back plus the bonus.
        assertEq(registry.claimable(id, alice), 0.024 ether);
        assertEq(registry.claimable(id, challenger), 0.06 ether + 0.003 ether);
        assertEq(registry.treasuryOwed(), 0.003 ether);
        _assertSettledWithoutCustody();
    }

    function _assertSettledWithoutCustody() internal view {
        IPoolManager m = IPoolManager(address(manager));
        assertFalse(m.isUnlocked());
        assertEq(m.getNonzeroDeltaCount(), 0);
        assertEq(m.currencyDelta(address(hook), ETH), 0);
        assertEq(m.currencyDelta(address(hook), key.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0, "no deferred native claims");
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0, "no deferred token claims");
        assertEq(hook.crownPaid(CRWN, key.currency1), 0, "all cuts are native ETH");
    }

    // ------------------------------------------------------------ fee collect by an LP with zero change

    function test_zeroLiquidityChangeCollectsWithoutHookDelta() public {
        swapper.swap(key, true, 1 ether);
        swapper.swap(key, false, 1e18);
        BalanceDelta d = lp.modify(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 0);
        assertGe(d.amount0(), 0);
        assertGe(d.amount1(), 0);
        assertGt(d.amount0(), 0, "LP fees accrued in ETH");
    }
}
