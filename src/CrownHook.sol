// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencyReserves} from "v4-core/src/libraries/CurrencyReserves.sol";
import {ICrownRegistry} from "./interfaces/ICrownRegistry.sol";
import {CrownRegistry} from "./CrownRegistry.sol";
import {ThroneRegistry} from "./ThroneRegistry.sol";

/// @title CrownHook
/// @notice A Uniswap v4 fee hook that skims a per-pool cut of every swap's native-ETH side and pays
/// it, inside the same swap, to the current king's beneficiary as recorded in `CrownRegistry`.
///
/// Pay-at-source: the hook never holds the cut. It is taken from the PoolManager straight to the
/// beneficiary while the swap settles, and the hook's delta nets to zero before the callback returns.
/// Nothing is pooled for claiming.
///
/// Never blocks a swap: when the registry is unset, the ticker unregistered, the registry read
/// reverts, the king has no beneficiary, the PoolManager holds no ETH to pay from, or the
/// beneficiary rejects the payment, the swap proceeds without the cut. The payment runs in its own
/// call frame (`payout`) that checks the PoolManager's accounting afterwards: a beneficiary that
/// accepts the ETH but leaves anything else behind in the unlocked PoolManager (an open delta of
/// its own, a settlement of somebody else's, a sync) is rolled back together with its payment, so
/// no beneficiary can hold the pool hostage.
///
/// The cut is always ETH, which is `currency0` of every native pool. When ETH is the swap's
/// specified amount (exact-input buy, exact-output sell) it is taken in `beforeSwap` through the
/// specified return delta; when ETH is the unspecified amount (exact-output buy, exact-input sell)
/// it is taken in `afterSwap` through the unspecified return delta. The launch token is never touched.
///
/// The cut follows the ETH the pool actually moves, never the order. In `afterSwap` that is the
/// swap's own delta. In `beforeSwap` the pool has not run yet, so the hook rehearses the exact swap
/// the pool is about to execute (`simulateSwap`, a self-call that always reverts and carries the
/// pool's delta back in its revert data): a partially filled order at its price limit, or one in a
/// pool without liquidity, pays the cut on what was filled, which for no fill is nothing.
contract CrownHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    // ---------------------------------------------------------------- parameters

    /// @notice Default per-pool cut, in basis points of the swap's ETH amount.
    uint16 public constant DEFAULT_CUT_BPS = 100;
    /// @notice Hard ceiling on any pool's cut.
    uint16 public constant MAX_CUT_BPS = 500;
    uint256 public constant BPS = 10_000;
    /// @notice Gas forwarded to the PoolManager for the beneficiary payment. Bounds what a hostile
    /// beneficiary can burn inside somebody else's swap; a plain wallet or a multisig needs far less.
    uint256 public constant PAYOUT_GAS = 150_000;
    /// @notice Largest ETH amount the hook quotes a cut on; a swap beyond it cannot settle in v4 anyway.
    uint256 public constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    // ---------------------------------------------------------------- types

    struct PoolConfig {
        bool initialized;
        bytes32 ticker;
        uint16 cutBps;
    }

    // ---------------------------------------------------------------- state

    IPoolManager public immutable poolManager;
    /// @notice Runtime code hashes of the two registries this hook accepts: `CrownRegistry` and its
    /// alias `ThroneRegistry`, as compiled with this hook. The owner can bind one of these and
    /// nothing else, so the king a pool pays is always resolved by the registry's own rules.
    bytes32 public immutable CROWN_REGISTRY_CODEHASH;
    bytes32 public immutable THRONE_REGISTRY_CODEHASH;
    /// @notice The registry, set once by the owner after launch; the zero address until then.
    ICrownRegistry public registry;
    mapping(PoolId => PoolConfig) public pools;
    /// @notice Cumulative cut paid out per ticker and currency.
    mapping(bytes32 ticker => mapping(Currency currency => uint256)) public crownPaid;

    // ---------------------------------------------------------------- events

    event RegistrySet(address indexed registry);
    event PoolInitialized(PoolId indexed poolId, Currency currency0, Currency currency1);
    event PoolRegistered(PoolId indexed poolId, bytes32 indexed ticker, uint16 cutBps);
    event CrownPaid(PoolId indexed poolId, bytes32 indexed ticker, address indexed beneficiary, uint256 amount);
    event CutSkipped(PoolId indexed poolId, bytes32 indexed ticker, uint256 amount, bytes32 reason);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotSelf();
    error HookNotImplemented();
    error RegistryAlreadySet();
    error PoolNotInitialized();
    error PoolAlreadyRegistered();
    error NotThisHook();
    error NotNativePool();
    error ZeroTicker();
    error ZeroAddress();
    error CutTooHigh(uint16 cutBps, uint16 maxCutBps);
    error NotCrownRegistry(address candidate);
    error RegistryNotSet();
    error KingIsNotPoolToken(bytes32 ticker, address king, address poolToken);
    error PayoutLeftTraces();

    // ---------------------------------------------------------------- constructor

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (written "$poolManager" in the manifest).
    /// @param owner_ The hook owner (written "$owner"): registers pools and sets the registry once.
    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
        CROWN_REGISTRY_CODEHASH = keccak256(type(CrownRegistry).runtimeCode);
        THRONE_REGISTRY_CODEHASH = keccak256(type(ThroneRegistry).runtimeCode);
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------- permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- owner

    /// @notice Point the hook at the registry. Once, after launch; immutable afterwards. Only a
    /// contract whose runtime code is exactly `CrownRegistry`'s (or `ThroneRegistry`'s) is accepted:
    /// the owner chooses which genuine registry instance governs, never what the rules are.
    function setRegistry(ICrownRegistry registry_) external onlyOwner {
        if (address(registry) != address(0)) revert RegistryAlreadySet();
        if (address(registry_) == address(0)) revert ZeroAddress();
        bytes32 codehash = address(registry_).codehash;
        if (codehash != CROWN_REGISTRY_CODEHASH && codehash != THRONE_REGISTRY_CODEHASH) {
            revert NotCrownRegistry(address(registry_));
        }
        registry = registry_;
        emit RegistrySet(address(registry_));
    }

    /// @notice Bind an initialized native-ETH pool of this hook to `ticker` with a cut of `cutBps`.
    /// Once per pool; the binding and the cut are immutable afterwards. The registry must already
    /// be set and the ticker's current king must be the pool's own token, so a pool can never be
    /// bound to a ticker somebody else crowned.
    function registerPool(PoolKey calldata key, bytes32 ticker, uint16 cutBps) external onlyOwner {
        if (address(key.hooks) != address(this)) revert NotThisHook();
        if (!key.currency0.isAddressZero()) revert NotNativePool();
        if (ticker == bytes32(0)) revert ZeroTicker();
        if (cutBps > MAX_CUT_BPS) revert CutTooHigh(cutBps, MAX_CUT_BPS);
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        if (!p.initialized) revert PoolNotInitialized();
        if (p.ticker != bytes32(0)) revert PoolAlreadyRegistered();
        ICrownRegistry reg = registry;
        if (address(reg) == address(0)) revert RegistryNotSet();
        address kingToken = reg.king(ticker).token;
        address poolToken = Currency.unwrap(key.currency1);
        if (kingToken != poolToken) revert KingIsNotPoolToken(ticker, kingToken, poolToken);
        p.ticker = ticker;
        p.cutBps = cutBps;
        emit PoolRegistered(id, ticker, cutBps);
    }

    // ---------------------------------------------------------------- callbacks

    /// @dev Records the pool with the default cut; the owner binds its ticker with `registerPool`
    /// (and may set another cut then). Accepts any sender: the launch factory initializes the pool.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        pools[id].initialized = true;
        pools[id].cutBps = DEFAULT_CUT_BPS;
        emit PoolInitialized(id, key.currency0, key.currency1);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Takes the cut when ETH is the specified amount: exact-input buys and exact-output sells.
    /// The cut is on the ETH the pool will actually move (see `_fillableEth`), not on the order.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = _abs(params.amountSpecified);
        uint256 paid = _payCut(key, _fillableEth(key, params, amount));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(paid)), 0), 0);
    }

    /// @notice Rehearses `params` on `key` and reverts with the pool's delta as 32 bytes of revert data.
    /// Only the hook itself may call it, from `beforeSwap`; nothing it does survives, since it always
    /// reverts. The PoolManager skips a hook's callbacks when the hook is the swapper, so the rehearsal
    /// never re-enters this contract.
    function simulateSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert NotSelf();
        int256 raw = BalanceDelta.unwrap(poolManager.swap(key, params, ""));
        assembly ("memory-safe") {
            mstore(0, raw)
            revert(0, 32)
        }
    }

    /// @dev Takes the cut when ETH is the unspecified amount: exact-output buys and exact-input sells.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_ethIsSpecified(params)) return (IHooks.afterSwap.selector, 0);
        uint256 paid = _payCut(key, _abs(delta.amount0()));
        return (IHooks.afterSwap.selector, int128(uint128(paid)));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------- views

    /// @notice The cut `amountEth` of ETH would carry on `poolId`; zero for an unregistered pool.
    function quoteCut(PoolId poolId, uint256 amountEth) public view returns (uint256) {
        PoolConfig storage p = pools[poolId];
        if (p.ticker == bytes32(0)) return 0;
        return (amountEth * p.cutBps) / BPS;
    }

    // ---------------------------------------------------------------- internals

    /// @dev ETH is `currency0` of every native pool. The specified currency is currency0 when the
    /// swap is exact-input zeroForOne or exact-output oneForZero.
    function _ethIsSpecified(SwapParams calldata params) internal pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    /// @dev Magnitude of a signed amount; `type(int).min` maps to 2^255 (or 2^127) instead of reverting.
    function _abs(int256 x) internal pure returns (uint256) {
        unchecked {
            return x < 0 ? uint256(-x) : uint256(x);
        }
    }

    /// @dev The ETH the pool will actually move for an order of `amount` ETH on its specified side.
    /// Rehearses the swap the pool is about to run under the largest cut the order could carry: if
    /// the pool fills all of it the cut is on the order; if it stops short (price limit, no liquidity)
    /// the cut is on what it filled. A rehearsal that fails (an order the pool itself will refuse)
    /// yields no cut, so the hook never blocks a swap.
    function _fillableEth(PoolKey calldata key, SwapParams calldata params, uint256 amount) internal returns (uint256) {
        if (amount > MAX_AMOUNT) return amount;
        uint256 cut = quoteCut(key.toId(), amount);
        if (cut == 0) return amount;
        bool exactInput = params.amountSpecified < 0;
        uint256 poolAmount = exactInput ? amount - cut : amount + cut;
        SwapParams memory trial = SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: exactInput ? -int256(poolAmount) : int256(poolAmount),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        try this.simulateSwap(key, trial) {
            return 0;
        } catch (bytes memory result) {
            if (result.length != 32) return 0;
            uint256 moved = _abs(BalanceDelta.wrap(abi.decode(result, (int256))).amount0());
            return moved < poolAmount ? moved : amount;
        }
    }

    /// @dev Pays the cut on `amount` ETH to the king's beneficiary; returns what was actually paid.
    /// Never reverts: every failure path returns 0 and the swap runs without the cut. When the
    /// PoolManager holds less ETH than the cut, what it holds is paid.
    function _payCut(PoolKey calldata key, uint256 amount) internal returns (uint256) {
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        bytes32 ticker = p.ticker;
        if (!key.currency0.isAddressZero() || amount > MAX_AMOUNT) return 0;
        uint256 cut = (amount * p.cutBps) / BPS;
        if (cut == 0) return 0;
        if (ticker == bytes32(0)) {
            if (p.initialized) emit CutSkipped(id, ticker, cut, "POOL_NOT_REGISTERED");
            return 0;
        }

        // A registered pool implies a bound registry (`registerPool` requires one, and it is immutable).
        ICrownRegistry reg = registry;
        // A raw staticcall: a revert, an empty answer or a malformed one all skip the cut instead
        // of reverting the swap (a high-level try/catch would still revert on bad return data).
        (bool ok, bytes memory data) = address(reg).staticcall(abi.encodeCall(ICrownRegistry.king, (ticker)));
        address beneficiary;
        bool wellFormed = ok && data.length == 96;
        if (wellFormed) {
            // The beneficiary is the second word. It is read by hand rather than with `abi.decode`,
            // which reverts on a word with bits set above the address; such an answer is malformed.
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(data, 64))
            }
            wellFormed = (word >> 160) == 0;
            beneficiary = address(uint160(word));
        }
        if (!wellFormed) {
            emit CutSkipped(id, ticker, cut, "REGISTRY_READ_FAILED");
            return 0;
        }
        if (beneficiary == address(0)) {
            emit CutSkipped(id, ticker, cut, "NO_KING");
            return 0;
        }
        // `take` pays from what the PoolManager already holds; the swapper settles only afterwards.
        // Pay what it holds when that is less than the cut, and nothing when it holds nothing.
        uint256 available = address(poolManager).balance;
        if (available == 0) {
            emit CutSkipped(id, ticker, cut, "MANAGER_SHORT_OF_ETH");
            return 0;
        }
        if (available < cut) cut = available;
        try this.payout(beneficiary, cut) {
            crownPaid[ticker][CurrencyLibrary.ADDRESS_ZERO] += cut;
            emit CrownPaid(id, ticker, beneficiary, cut);
            return cut;
        } catch {
            emit CutSkipped(id, ticker, cut, "BENEFICIARY_REJECTED");
            return 0;
        }
    }

    /// @notice Pays `cut` ETH from the PoolManager to `beneficiary` and reverts unless the only trace
    /// the payment left in the PoolManager is the hook's own `-cut` delta. Only the hook may call it,
    /// from `_payCut`, which catches the revert: a beneficiary that re-enters the unlocked
    /// PoolManager during its payment (opens a delta, settles somebody's, syncs a currency) is
    /// rolled back together with its payment, and the swap proceeds without the cut.
    function payout(address beneficiary, uint256 cut) external {
        if (msg.sender != address(this)) revert NotSelf();
        IPoolManager pm = poolManager;
        uint256 deltasBefore = pm.getNonzeroDeltaCount();
        int256 hookDeltaBefore = pm.currencyDelta(address(this), CurrencyLibrary.ADDRESS_ZERO);
        uint256 balanceBefore = address(pm).balance;
        bytes32 syncedCurrencyBefore = pm.exttload(CurrencyReserves.CURRENCY_SLOT);
        bytes32 syncedReservesBefore = pm.exttload(CurrencyReserves.RESERVES_OF_SLOT);

        pm.take{gas: PAYOUT_GAS}(CurrencyLibrary.ADDRESS_ZERO, beneficiary, cut);

        // The hook's delta went from zero to -cut and nothing else moved: no other delta was opened
        // or closed, no ETH entered or left beyond the cut, no currency was synced or settled.
        if (
            pm.getNonzeroDeltaCount() != deltasBefore + 1 || hookDeltaBefore != 0
                || pm.currencyDelta(address(this), CurrencyLibrary.ADDRESS_ZERO) != -int256(cut)
                || address(pm).balance != balanceBefore - cut
                || pm.exttload(CurrencyReserves.CURRENCY_SLOT) != syncedCurrencyBefore
                || pm.exttload(CurrencyReserves.RESERVES_OF_SLOT) != syncedReservesBefore
        ) revert PayoutLeftTraces();
    }
}
