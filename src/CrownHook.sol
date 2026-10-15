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
import {ICrownRegistry} from "./interfaces/ICrownRegistry.sol";

/// @title CrownHook
/// @notice A Uniswap v4 fee hook that skims a per-pool cut of every swap's native-ETH side and pays
/// it, inside the same swap, to the current king's beneficiary as recorded in `CrownRegistry`.
///
/// Pay-at-source: the hook never holds the cut. It is taken from the PoolManager straight to the
/// beneficiary while the swap settles, and the hook's delta nets to zero before the callback returns.
/// Nothing is pooled for claiming.
///
/// Never blocks a swap: when the registry is unset, the ticker unregistered, the registry read
/// reverts, the king has no beneficiary, the PoolManager does not hold enough ETH to pay, or the
/// beneficiary rejects the payment, the swap proceeds without the cut.
///
/// The cut is always ETH, which is `currency0` of every native pool. When ETH is the swap's
/// specified amount (exact-input buy, exact-output sell) it is taken in `beforeSwap` through the
/// specified return delta; when ETH is the unspecified amount (exact-output buy, exact-input sell)
/// it is taken in `afterSwap` through the unspecified return delta. The launch token is never touched.
contract CrownHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- parameters

    /// @notice Default per-pool cut, in basis points of the swap's ETH amount.
    uint16 public constant DEFAULT_CUT_BPS = 100;
    /// @notice Hard ceiling on any pool's cut.
    uint16 public constant MAX_CUT_BPS = 500;
    uint256 public constant BPS = 10_000;
    /// @notice Gas forwarded to the PoolManager for the beneficiary payment. Bounds what a hostile
    /// beneficiary can burn inside somebody else's swap; a plain wallet or a multisig needs far less.
    uint256 public constant PAYOUT_GAS = 150_000;

    // ---------------------------------------------------------------- types

    struct PoolConfig {
        bool initialized;
        bytes32 ticker;
        uint16 cutBps;
    }

    // ---------------------------------------------------------------- state

    IPoolManager public immutable poolManager;
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
    error HookNotImplemented();
    error RegistryAlreadySet();
    error PoolNotInitialized();
    error PoolAlreadyRegistered();
    error NotThisHook();
    error NotNativePool();
    error ZeroTicker();
    error ZeroAddress();
    error CutTooHigh(uint16 cutBps, uint16 maxCutBps);

    // ---------------------------------------------------------------- constructor

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (written "$poolManager" in the manifest).
    /// @param owner_ The hook owner (written "$owner"): registers pools and sets the registry once.
    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
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

    /// @notice Point the hook at the registry. Once, after launch; immutable afterwards.
    function setRegistry(ICrownRegistry registry_) external onlyOwner {
        if (address(registry) != address(0)) revert RegistryAlreadySet();
        if (address(registry_) == address(0) || address(registry_).code.length == 0) revert ZeroAddress();
        registry = registry_;
        emit RegistrySet(address(registry_));
    }

    /// @notice Bind an initialized native-ETH pool of this hook to `ticker` with a cut of `cutBps`.
    /// Once per pool; the binding and the cut are immutable afterwards.
    function registerPool(PoolKey calldata key, bytes32 ticker, uint16 cutBps) external onlyOwner {
        if (address(key.hooks) != address(this)) revert NotThisHook();
        if (!key.currency0.isAddressZero()) revert NotNativePool();
        if (ticker == bytes32(0)) revert ZeroTicker();
        if (cutBps > MAX_CUT_BPS) revert CutTooHigh(cutBps, MAX_CUT_BPS);
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        if (!p.initialized) revert PoolNotInitialized();
        if (p.ticker != bytes32(0)) revert PoolAlreadyRegistered();
        p.ticker = ticker;
        p.cutBps = cutBps;
        emit PoolRegistered(id, ticker, cutBps);
    }

    // ---------------------------------------------------------------- callbacks

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        pools[id].initialized = true;
        emit PoolInitialized(id, key.currency0, key.currency1);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Takes the cut when ETH is the specified amount: exact-input buys and exact-output sells.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 paid = _payCut(key, amount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(paid)), 0), 0);
    }

    /// @dev Takes the cut when ETH is the unspecified amount: exact-output buys and exact-input sells.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_ethIsSpecified(params)) return (IHooks.afterSwap.selector, 0);
        int128 eth = delta.amount0();
        uint256 amount = eth < 0 ? uint256(uint128(-eth)) : uint256(uint128(eth));
        uint256 paid = _payCut(key, amount);
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

    /// @dev Pays the cut on `amount` ETH to the king's beneficiary; returns what was actually paid.
    /// Never reverts: every failure path returns 0 and the swap runs without the cut.
    function _payCut(PoolKey calldata key, uint256 amount) internal returns (uint256) {
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        bytes32 ticker = p.ticker;
        if (ticker == bytes32(0) || !key.currency0.isAddressZero()) return 0;
        uint256 cut = (amount * p.cutBps) / BPS;
        if (cut == 0 || cut > uint256(uint128(type(int128).max))) return 0;

        ICrownRegistry reg = registry;
        if (address(reg) == address(0)) {
            emit CutSkipped(id, ticker, cut, "NO_REGISTRY");
            return 0;
        }
        // A raw staticcall: a revert, an empty answer or a malformed one all skip the cut instead
        // of reverting the swap (a high-level try/catch would still revert on bad return data).
        (bool ok, bytes memory data) = address(reg).staticcall(abi.encodeCall(ICrownRegistry.king, (ticker)));
        if (!ok || data.length != 96) {
            emit CutSkipped(id, ticker, cut, "REGISTRY_READ_FAILED");
            return 0;
        }
        (, address beneficiary,) = abi.decode(data, (address, address, uint64));
        if (beneficiary == address(0)) {
            emit CutSkipped(id, ticker, cut, "NO_KING");
            return 0;
        }
        // `take` pays from what the PoolManager already holds; the swapper settles only afterwards.
        if (address(poolManager).balance < cut) {
            emit CutSkipped(id, ticker, cut, "MANAGER_SHORT_OF_ETH");
            return 0;
        }
        try poolManager.take{gas: PAYOUT_GAS}(CurrencyLibrary.ADDRESS_ZERO, beneficiary, cut) {
            crownPaid[ticker][CurrencyLibrary.ADDRESS_ZERO] += cut;
            emit CrownPaid(id, ticker, beneficiary, cut);
            return cut;
        } catch {
            emit CutSkipped(id, ticker, cut, "BENEFICIARY_REJECTED");
            return 0;
        }
    }
}
