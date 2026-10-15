# CROWN — per-ticker crown registry and Uniswap v4 fee hook

One canonical token per ticker: the king. `CrownRegistry` maps a ticker (`keccak256` of the
upper-cased symbol) to `{token, beneficiary, reignStartedAt}`. `CrownHook` sits on Uniswap v4 pools,
skims a per-pool cut of every swap's ETH side and pays it, inside the same swap, to the current
king's beneficiary. Anyone can challenge a king with a bonded ETH stake-vote; if the challenger side
out-stakes the king side within the window and quorum is met, the crown flips after a timelock and
every later swap pays the new king.

This repository is the contracts, their tests, a post-launch script and a static ticker page.
Launch chain: Robinhood Chain (chain id 4663), pool paired with native ETH, LP fee 12500 (1.25%),
tick spacing 60.

## Contracts

| Contract | File | Role |
| --- | --- | --- |
| `CrownRegistry` | `src/CrownRegistry.sol` | Kings, challenges, stakes, finalization, pull-pattern payouts. No admin. |
| `ThroneRegistry` | `src/ThroneRegistry.sol` | The same contract under the assignment's name (`is CrownRegistry`, nothing added). Launch one of the two, not both. |
| `CrownHook` | `src/CrownHook.sol` | Uniswap v4 hook: `afterInitialize`, `beforeSwap`, `afterSwap`, both swap return deltas. |
| `CrownToken` | `src/CrownToken.sol` | The launch token "Crown Demo" (CRWN): fixed 1,000,000,000 × 10^18 minted to its deployer, no constructor arguments, no mint/owner/pause/fee. |
| `CrownChallengerToken` | `src/CrownChallengerToken.sol` | A second, distinct plain CRWN ERC-20 (same name and symbol), the standing challenger candidate. Minted to a constructor-given recipient. Deployed by `script/DeployCrown.s.sol`, not by the launch. |
| `HookFlags` | `src/HookFlags.sol` | Internal library of the v4 permission bits (used by tests and the floor suite). |
| `ICrownRegistry` | `src/interfaces/ICrownRegistry.sol` | The read the hook performs: `king(bytes32)`. |

### CrownRegistry rules

All parameters are constants (the brief fixes them; nothing can change them after deployment):

| Constant | Value |
| --- | --- |
| `BOND` | 0.01 ETH, the challenger's opening stake |
| `MIN_REIGN` | 7 days before a king can be challenged (from `reignStartedAt`) |
| `STAKE_WINDOW` | 72 hours of staking after `openChallenge` |
| `TIMELOCK` | 24 hours after the window before `finalize` |
| `QUORUM` | 0.05 ETH total staked (both sides, bond included) |
| `COOLDOWN` | 3 days per ticker after a failed challenge |
| `SLASH_BPS` | 2,000 (20% of the losing side) |
| `TREASURY` | `0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57` |

- `registerKing(ticker, token, beneficiary)`: the first registration for a ticker crowns that token.
  Permissionless and first-come, which is why the launch crowns CRWN in the constructor (below).
- `openChallenge(ticker, challengerToken)` payable, exactly `BOND`: one live challenge per ticker; only
  after `MIN_REIGN`; not during a cooldown; not with the king's own token. The caller becomes the
  challenger token's beneficiary if the challenge succeeds. The bond is the challenger's first stake.
- `stake(challengeId, side)` payable, any amount, while `block.timestamp < windowEnd`.
- `finalize(challengeId)`, anyone, once `block.timestamp >= windowEnd + TIMELOCK`. The challenger wins
  iff `challengerStake > kingStake` and `kingStake + challengerStake >= QUORUM`. On a flip the registry
  points to the challenger token and its beneficiary and `reignStartedAt` resets; on a failure the
  cooldown starts and the reign is untouched.
- Payouts are pull-only. `claim(challengeId)` pays a staker both sides at once:
  winning-side stake in full plus `winnerBonus × stake / winningTotal`; losing-side stake × 80%, floored.
  `winnerBonus` is half of the slash; the other half accrues to `treasuryOwed`, which anyone sends to
  `TREASURY` with `withdrawTreasury()`. If the winning side has no stake at all (nobody backed the
  king and the challenge still failed), the whole slash goes to the treasury.
- Rounding: pro-rata shares and the 80% refund are floored per staker, so the contract never owes
  more than it holds; the dust (under one wei per stake share) stays in the contract. The fuzz test
  `testFuzz_conservation` checks this.
- Events: `Crowned`, `ChallengeOpened`, `Staked`, `Dethroned`, `ChallengeFailed`, `Claimed`,
  `TreasuryWithdrawn`. Public per-ticker totals: `tickerTotals(ticker)` (challenges opened,
  dethronements, ETH ever staked per side), `liveChallenge(ticker)`, `cooldownUntil(ticker)`,
  `challenges(id)` with both running stakes, `claimable(id, staker)`, `tickerOf(symbol)`.

Constructor: `(string genesisSymbol, address genesisToken, address genesisBeneficiary)`. It crowns
`tickerOf(genesisSymbol)` at deployment, so no one can front-run the genesis registration. Passing
`("", 0, 0)` deploys with no genesis crown; a partial genesis reverts. The constructor calls no
other contract.

### CrownHook

Permissions (encoded in the mined address, `0x10CC`): `afterInitialize`, `beforeSwap`,
`afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. The brief lists `afterSwap` and
`afterSwapReturnDelta`; the others were added because:

- `afterInitialize` records the pool and is the initialization callback the launch requires, so nobody
  can initialize the predicted pool before the factory deploys the hook. It accepts any sender (the
  factory initializes the launch pool).
- `beforeSwap` + `beforeSwapReturnDelta` are needed to take the cut in ETH when ETH is the swap's
  *specified* amount (exact-input buy, exact-output sell). An after-swap delta can only touch the
  unspecified currency. The cut is always taken from the ETH side and never from the launch token.

What happens on a swap of a registered native-ETH pool:

1. Determine whether ETH (always `currency0` of a native pool) is the specified or unspecified
   amount: `(amountSpecified < 0) == zeroForOne` means specified.
2. Compute `cut = amount × cutBps / 10,000` of the ETH the pool actually moves, never of the order.
   In `afterSwap` that is `delta.amount0()`. In `beforeSwap` the pool has not run yet, so the hook
   rehearses the exact swap the pool is about to execute (the order minus the largest possible cut
   on a buy, plus it on a sell, at the caller's price limit): `simulateSwap` is a self-call that
   performs `poolManager.swap` and always reverts, carrying the pool's delta back in 32 bytes of
   revert data. If the pool fills the whole order the cut is on the order (1% of 1 ETH in is
   0.01 ETH); if it stops short at the price limit, or the pool has no liquidity, the cut is on what
   was filled, which for nothing filled is nothing. The PoolManager skips a hook's callbacks when
   the hook is the swapper, so the rehearsal never re-enters the hook, and nothing it does survives
   its revert. A rehearsal that fails (an order the pool itself will refuse) yields no cut. The cost
   is roughly a second swap's gas on exact-input buys and exact-output sells.
3. Read `registry.king(ticker).beneficiary` with a raw staticcall and decode the beneficiary word by
   hand: an answer that is not exactly 96 bytes, or whose beneficiary word has bits set above the
   address, is malformed and skips the cut (`abi.decode` would revert the swap on it).
4. If the PoolManager's ETH balance covers it, `poolManager.take(ETH, beneficiary, cut)` pays the
   beneficiary at once, with at most `PAYOUT_GAS` (150,000) gas, and the callback returns `+cut` as
   the hook delta, so the hook's own delta nets to zero before the callback returns. The swapper pays
   the cut on top of the pool's input (buys) or receives the pool's output minus the cut (sells).
5. `crownPaid[ticker][currency]` grows by exactly what was transferred; `CrownPaid` is emitted.

The hook never holds funds and never reverts a swap. Every failure path skips the cut and emits
`CutSkipped(poolId, ticker, cut, reason)`:

| Reason | When |
| --- | --- |
| `NO_REGISTRY` | the owner has not set the registry yet |
| `REGISTRY_READ_FAILED` | the registry read reverts, or returns data that is not 96 bytes or whose beneficiary word is not a clean address |
| `NO_KING` | the pool's ticker has no king (beneficiary is zero) |
| `MANAGER_SHORT_OF_ETH` | the PoolManager holds less ETH than the cut (see below) |
| `BENEFICIARY_REJECTED` | the beneficiary refuses ETH or burns more than `PAYOUT_GAS` |

Pay-at-source versus a fresh PoolManager: `take` pays from what the PoolManager already holds, and the
swapper settles only after the hook runs. The launch pool is seeded with tokens only, so the first
ETH-paying buy on a PoolManager that holds no ETH is executed without the cut, and the ETH it
settles funds the cut of every later swap (`test_freshManagerSeededWithTokensOnly`). The brief
forbids storing or pooling fees for claiming, so this is handled by skipping rather than by minting
an ERC-6909 claim. A beneficiary contract that rejects ETH does not halt trading: its cuts are
skipped until the crown changes hands.

Owner functions (owner = `$owner`, the launch payer; never the factory or `tx.origin`):

- `setRegistry(registry)`: once; must be a contract; immutable afterwards.
- `registerPool(key, ticker, cutBps)`: once per pool; the pool must be initialized through this hook
  and have native ETH as `currency0`; `cutBps` ≤ `MAX_CUT_BPS` (500); `DEFAULT_CUT_BPS` is 100.
  Immutable afterwards, so the owner cannot change a pool's cut or ticker later.

There are no other admin functions, no pause, no upgrade. The owner may `renounceOwnership()` after
setup. Liquidity callbacks are not enabled, so the factory's zero-liquidity fee collect passes
through untouched.

External calls the hook makes, all inside the PoolManager's unlock: the registry read (staticcall),
`poolManager.take` for the beneficiary payment, and the rehearsal self-call `simulateSwap`, which
only the hook may invoke (`NotSelf` otherwise) and which calls `poolManager.swap` and reverts. The
hook holds no funds and has no storage the rehearsal could touch.

Wizard-style configuration record for the hook:

```json
{
  "hook": "BaseHook", "name": "CrownHook", "pausable": false,
  "currencySettler": false, "safeCast": false, "transientStorage": false,
  "shares": {"options": false},
  "permissions": {"beforeInitialize": false, "afterInitialize": true, "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterAddLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true, "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false},
  "access": "ownable", "info": {"license": "MIT"}
}
```

`BaseHook` from v4-periphery is not vendored; the hook implements `IHooks` directly with an
`onlyPoolManager` check on every enabled callback and `HookNotImplemented` on the others.

## Launch parameters

| Contract | Constructor arguments |
| --- | --- |
| `CrownToken` | none |
| `CrownRegistry` (or `ThroneRegistry`) | `("CRWN", "$token", "$owner")` — genesis king CRWN = the launch token, beneficiary = the launch payer |
| `CrownHook` | `("$poolManager", "$owner")` |

Pool: `currency0` = native ETH (zero address), `currency1` = the launch token, fee 12500, tick
spacing 60, hooks = `CrownHook`. The deployer sets the opening price.

The launch token is exactly what the launch policy requires. The brief asks for nothing from it
beyond its name and symbol; the swap fee is in the hook.

## After launch (owner's checklist)

1. `CrownHook.setRegistry(<CrownRegistry address>)` — the registry the launch deployed.
2. `CrownHook.registerPool(poolKey, keccak256("CRWN"), 100)` — the launch pool's key (ETH, token,
   12500, 60, hook) and the cut in bps (100 = 1%, maximum 500). Until both are done, swaps run without
   the cut. `script/DeployCrown.s.sol:configureHook` does both when sent by the owner.
3. Deploy the standing challenger: `CrownChallengerToken(<recipient>)`, for example with
   `CROWN_CHALLENGER_RECIPIENT=<addr> forge script script/DeployCrown.s.sol --broadcast`.
4. Optionally `renounceOwnership()` on the hook once configured.

Operational notes: `CrownRegistry` has no owner and no parameters to maintain. `finalize` and
`withdrawTreasury` are permissionless and must be called by someone (a keeper, the site, anyone);
nothing pays out automatically. Stakers pull with `claim`. The king's beneficiary must be able to
receive plain ETH transfers within 150,000 gas, or its cuts are skipped.

## Demo flow (what the integration test does)

`test/CrownHook.t.sol:test_endToEndDethroneChangesFeeRecipient`: buy (cut to the genesis wallet) →
`openChallenge` with `CrownChallengerToken` → stakes on both sides → `finalize` after 96 hours →
buy and sell (every cut to the challenger, the old wallet unchanged) and `crownPaid` equals the sum
of every transfer. The same sequence on Robinhood Chain uses the owner's checklist above, then the
registry calls from any wallet.

## Site

`site/index.html` is a static ticker page (vanilla JS + ethers v6 from a CDN, no build step). Fill
the addresses at the top of the file after launch. It shows the current king, `crownPaid` totals,
the live challenge (window, both stakes, time remaining), and wires `openChallenge`, `stake`,
`finalize` and `claim` to an injected wallet, with a plain-English how-it-works section.

## Build, test, verify

```
forge build
FOUNDRY_FUZZ_SEED=0x27da370e51768f0c2b8c6dddefd6cea65c06968db613797d0307b6a6c0cbe16f forge test
forge fmt --check
```

Compiler settings (`foundry.toml`), also what Sourcify needs: solc 0.8.26, EVM version cancun,
optimizer on, 44,444 runs, `via_ir = false`, `bytecode_hash = "none"` (CBOR metadata keeps only the
solc version). Dependencies are vendored as plain files in `lib/` (versions in `lib/VERSIONS.txt`):
Uniswap v4-core, forge-std, OpenZeppelin Contracts v5.1.0, solmate's `Owned.sol` (needed by
v4-core's `ProtocolFees`).

Tests (54): `test/CrownRegistry.t.sol` (bond, reign, window, timelock, quorum boundary and tie,
exact-wei slash split for a flip, a failed challenge and a no-quorum challenge, empty winning side,
pull claims, rejecting receiver, fuzzed conservation of funds), `test/CrownHook.t.sol` (permissions
and address bits, caller checks, owner setters, all four swap shapes on a funded manager, fuzzed
cut, an unfilled order in an empty pool and price-limited partial fills in both directions paying
the cut only on the executed ETH, the rehearsal refusing outside callers, every skip reason
including a malformed registry answer, a fresh tokens-only PoolManager and a rejecting
beneficiary, the end-to-end dethrone, a zero-liquidity collect), `test/CrownToken.t.sol`,
`test/DeployCrown.t.sol`.
`test/mocks` and `test/floor` hold the routers and owner checks the floor suite imports.

## Assumptions and open points

- The challenger's beneficiary is the wallet that calls `openChallenge` (the brief's signature has
  no beneficiary argument).
- The bond counts as challenger stake (toward quorum and the vote) and is refunded or slashed like
  any other stake.
- Rounding dust from pro-rata shares stays in the registry; it is bounded by one wei per stake share.
- The cut currency is always native ETH; `registerPool` refuses pools whose `currency0` is not ETH.
  `crownPaid` is keyed by currency anyway, as the brief asks.
- `PAYOUT_GAS` (150,000) is a chosen constant: it caps what a hostile beneficiary can burn inside
  someone else's swap.
- Tests pass with an empty environment and in any order; none reads env vars.
- Tests are not an audit: an independent adversarial review is still needed before funds are at
  stake.
