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

/// @dev A beneficiary that refuses ETH.
contract EthRejecter {}

contract CrownHookTest is Test {
    using PoolIdLibrary for PoolKey;

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

    // ------------------------------------------------------------ never blocks a swap

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
        uint256 kingBefore = kingWallet.balance;
        uint256 chalBefore = challenger.balance;

        // 1. Buy: the cut goes to the genesis king's wallet.
        swapper.swap(key, true, 2 ether);
        assertEq(kingWallet.balance - kingBefore, 0.02 ether);
        assertEq(hook.crownPaid(CRWN, ETH), 0.02 ether);

        // 2. Challenge with the standing challenger token once the reign is old enough.
        CrownChallengerToken rival = new CrownChallengerToken(challenger);
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

        // 4. Finalize after window + timelock: the crown flips.
        vm.warp(registry.challenges(id).finalizeAfter);
        registry.finalize(id);
        ICrownRegistry.King memory k = registry.king(CRWN);
        assertEq(k.token, address(rival));
        assertEq(k.beneficiary, challenger);

        // 5. Buy and sell: every cut now goes to the challenger; the old king gets nothing more.
        swapper.swap(key, true, 1 ether);
        assertEq(challenger.balance - chalBefore, 0.01 ether, "the new king is paid");
        assertEq(kingWallet.balance - kingBefore, 0.03 ether, "the old king is not");
        uint256 sellBefore = challenger.balance;
        swapper.swap(key, false, 1e18);
        uint256 sellCut = challenger.balance - sellBefore;
        assertGt(sellCut, 0);

        // crownPaid matches every transfer made.
        assertEq(hook.crownPaid(CRWN, ETH), 0.03 ether + 0.01 ether + sellCut);
        assertEq(hook.crownPaid(CRWN, ETH), (kingWallet.balance - kingBefore) + (challenger.balance - chalBefore));

        // Stakers pull their money: alice lost 20% of 0.03; challenger gets stake back plus the bonus.
        assertEq(registry.claimable(id, alice), 0.024 ether);
        assertEq(registry.claimable(id, challenger), 0.06 ether + 0.003 ether);
        assertEq(registry.treasuryOwed(), 0.003 ether);
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
