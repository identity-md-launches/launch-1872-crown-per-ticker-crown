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
- `openChallenge(ticker, challengerToken)` payable, exactly `requiredBond(ticker)`: `BOND` when no
  challenge is live, or exactly twice the live challenge's bond to *displace* it while it is still in
  its staking window (nothing can be opened while a live challenge is past its window and being
  decided: `ChallengeLive`). Only after `MIN_REIGN`; not during a cooldown; not with the king's own
  token. The caller becomes the challenger token's beneficiary if the challenge succeeds. The bond is
  the challenger's first stake.
- Displacement (`ChallengeDisplaced`): the displaced challenge is finalized at once with
  `displacedBy` set, nothing slashed, no cooldown and no crown change; every stake on both sides is
  refundable in full through `claim`. The new challenge starts its own 72-hour window with the
  doubled bond as its challenger stake. This is the rule decision behind the "one live challenge per
  ticker" slot: a king (or an ally) who opens a sham challenge against itself to keep outsiders out
  can be displaced for 0.02 ETH, and each further round doubles the bond at stake, so the slot can be
  held only by out-bonding every rival, never for free. The 7-day minimum reign after a genuine flip
  and the 3-day cooldown after a genuinely failed challenge are unchanged.
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
- Events: `Crowned`, `ChallengeOpened`, `ChallengeDisplaced`, `Staked`, `Dethroned`,
  `ChallengeFailed`, `Claimed`, `TreasuryWithdrawn`. Public per-ticker totals: `tickerTotals(ticker)`
  (challenges opened, dethronements, ETH ever staked per side), `liveChallenge(ticker)`,
  `cooldownUntil(ticker)`, `requiredBond(ticker)`, `challenges(id)` with both running stakes, its
  `bond` and `displacedBy`, `claimable(id, staker)`, `tickerOf(symbol)`.

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
4. The payment runs in its own call frame, `payout(beneficiary, cut)` (an external self-call only
   the hook may make): it snapshots the PoolManager's nonzero-delta count, the hook's own ETH delta,
   the manager's ETH balance and its synced-currency and reserves slots, performs
   `poolManager.take(ETH, beneficiary, cut)` with at most `PAYOUT_GAS` (150,000) gas, and then
   reverts (`PayoutLeftTraces`) unless the only change is the hook's own `-cut` delta: the count grew
   by exactly one, the hook's delta is exactly `-cut`, the balance fell by exactly `cut`, and no
   currency was synced or settled. `_payCut` catches that revert, which rolls back the transfer
   *and everything the beneficiary did while being paid*, and the swap runs without the cut
   (`BENEFICIARY_REJECTED`). So a beneficiary contract that accepts the ETH and, inside `receive()`,
   re-enters the unlocked PoolManager to leave a delta open (its own `mint`/`take`, a `settleFor` of
   somebody else's debt, a `sync`) cannot make the swapper's unlock end in `CurrencyNotSettled`; its
   re-entry is undone and it simply forfeits that cut. On success the callback returns `+cut` as the
   hook delta, so the hook's own delta nets to zero before the callback returns. The swapper pays
   the cut on top of the pool's input (buys) or receives the pool's output minus the cut (sells).
   If the PoolManager holds less ETH than the cut, what it holds is paid (`min(cut, balance)`); if it
   holds none, the cut is skipped.
5. `crownPaid[ticker][currency]` grows by exactly what was transferred; `CrownPaid` is emitted with
   that amount.

The hook never holds funds and never reverts a swap. Every failure path skips the cut and emits
`CutSkipped(poolId, ticker, cut, reason)`:

| Reason | When |
| --- | --- |
| `POOL_NOT_REGISTERED` | the pool is initialized but the owner has not bound its ticker yet (`ticker` is zero in the event; the amount is the default cut it would have charged) |
| `REGISTRY_READ_FAILED` | the registry read reverts, or returns data that is not 96 bytes or whose beneficiary word is not a clean address |
| `NO_KING` | the pool's ticker has no king (beneficiary is zero) |
| `MANAGER_SHORT_OF_ETH` | the PoolManager holds no ETH at all (see below); a partial balance is paid, not skipped |
| `BENEFICIARY_REJECTED` | the beneficiary refuses ETH, burns more than `PAYOUT_GAS`, or re-entered the PoolManager during its payment (the whole payment is rolled back) |

Pay-at-source versus a fresh PoolManager: `take` pays from what the PoolManager already holds, and the
swapper settles only after the hook runs. The launch pool is seeded with tokens only, so the first
ETH-paying buy on a PoolManager that holds no ETH is executed without the cut; after it the manager
holds that buy's ETH, and every later cut is paid in full when the manager's ETH covers it and
otherwise up to what it holds (`test_freshManagerSeededWithTokensOnly`,
`test_partialCutWhenManagerHoldsLessThanTheCut`). The brief forbids storing or pooling fees for
claiming, so a shortfall is paid partially or skipped rather than minted as an ERC-6909 claim. A
beneficiary contract that rejects ETH, or misbehaves while being paid, does not halt trading: its
cuts are skipped until the crown changes hands.

Owner functions (owner = `$owner`, the launch payer; never the factory or `tx.origin`):

- `setRegistry(registry)`: once; immutable afterwards. The address's runtime code hash must equal
  `CROWN_REGISTRY_CODEHASH` or `THRONE_REGISTRY_CODEHASH`, immutables the constructor computes from
  `type(CrownRegistry).runtimeCode` / `type(ThroneRegistry).runtimeCode` (the registry has no
  immutables and the build strips metadata, so a registry compiled with these settings matches byte
  for byte). The owner therefore picks *which genuine registry instance* the pool follows, and with it
  the genesis crown; it cannot bind a contract of its own making whose `king` names whoever it likes,
  and after the binding nothing but the registry's rules decides who is paid.
- `registerPool(key, ticker, cutBps)`: once per pool; the registry must be set; the pool must be
  initialized through this hook and have native ETH as `currency0`; `cutBps` ≤ `MAX_CUT_BPS` (500);
  and `registry.king(ticker).token` must be the pool's `currency1` (`KingIsNotPoolToken`), so a pool
  can only be bound to the ticker its own token is king of; a ticker somebody squatted first cannot
  capture another pool's cut. `afterInitialize` records every pool with `DEFAULT_CUT_BPS` (100);
  `registerPool` binds the ticker and may set another cut. Immutable afterwards, so the owner cannot
  change a pool's cut or ticker later.

There are no other admin functions, no pause, no upgrade. The owner may `renounceOwnership()` after
setup. Liquidity callbacks are not enabled, so the factory's zero-liquidity fee collect passes
through untouched.

External calls the hook makes, all inside the PoolManager's unlock: the registry read (staticcall),
the payment self-call `payout` (which performs `poolManager.take` and reads the manager's transient
accounting through `exttload`), and the rehearsal self-call `simulateSwap`, which calls
`poolManager.swap` and reverts. Both self-calls refuse every caller but the hook (`NotSelf`). The
hook holds no funds and has no storage either self-call could touch.

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
   12500, 60, hook) and the cut in bps (100 = 1%, maximum 500); it requires step 1 and a registry
   whose CRWN king is the launch token. Until both are done, swaps run without the cut and emit
   `CutSkipped(..., "POOL_NOT_REGISTERED")`. `script/DeployCrown.s.sol:configureHook` does both when
   sent by the owner. The registry the factory does not deploy is the reason this gap exists; the
   hook's constructor and `setRegistry`/`registerPool` signatures are fixed by the accepted floor and
   proof harnesses, so the binding stays a one-time owner step restricted to a bytecode-identical
   `CrownRegistry`.
3. Deploy the standing challenger: `CrownChallengerToken(<recipient>)`, for example with
   `CROWN_CHALLENGER_RECIPIENT=<addr> forge script script/DeployCrown.s.sol --broadcast`.
4. Optionally `renounceOwnership()` on the hook once configured.

Operational notes: `CrownRegistry` has no owner and no parameters to maintain. `finalize` and
`withdrawTreasury` are permissionless and must be called by someone (a keeper, the site, anyone);
nothing pays out automatically. Stakers pull with `claim`. The king's beneficiary must be able to
receive plain ETH transfers within 150,000 gas without touching the PoolManager, or its cuts are
skipped.

## Demo flow (what the integration test does)

`test/CrownHook.t.sol:test_endToEndDethroneChangesFeeRecipient`: buy (cut to the genesis wallet) →
`openChallenge` with `CrownChallengerToken` → stakes on both sides → `finalize` after 96 hours →
buy and sell (every cut to the challenger, the old wallet unchanged) and `crownPaid` equals the sum
of every transfer. The same sequence on Robinhood Chain uses the owner's checklist above, then the
registry calls from any wallet.

## Frontend

The canonical ticker page is the Vite + React + TypeScript application in `web/`. Its complete static export is `dist/`, including `index.html`, local assets, implementation-derived ABI arrays and `imd-deployment.json`. The older `site/index.html` prototype is retained as prior contributor work; it is not the published entrypoint.

**Deployment status:** this assignment supplied no `.imd/reads/deployment.json` or `.imd/reads/network.json`. The export therefore has an empty contract set and clearly shows “Awaiting launch” / “Not live”. It has no invented addresses, transaction history, balances or deployment identifiers. Wallet connection is available; financial actions remain disabled until a genuine handoff is supplied. The deployment and live funded demo remain the launch workflow’s responsibility. Nothing was broadcast by this frontend worker.

### Install, build and preview

Use Node 24 and the existing Foundry toolchain. From the repository root:

```sh
forge build
node web/scripts/build-worker.mjs
python3 -m http.server 4173 --directory dist
```

The worker build copies frontend sources into `test/scratch/web`, installs with `npm ci` from `web/package-lock.json`, runs TypeScript and Vite, and writes the production export to root `dist/`. Dependencies stay in disposable scratch and npm’s cache stays under `/tmp`; neither is submitted. No ignore file was changed. The production preview is `http://localhost:4173/`; it also works at a static subpath, as exercised at `/preview/` in the browser tests. HTTPS or localhost is needed for wallet and clipboard APIs.

After the first installation, rebuild with `node web/scripts/build-worker.mjs --installed`. Development with hot reload uses the same runtime deployment file:

```sh
CROWN_OUT_DIR="$PWD/dist" npm --prefix test/scratch/web run dev
```

The development middleware serves the manifest and ABIs from `dist/`, so it does not create another address configuration. This middleware is for development only; the production app needs no server beyond static file hosting. `npm run build`, `npm run typecheck`, `npm run dev` and `npm run preview` are also standard package scripts in `web/package.json`.

### Bind the actual launch

`web/src/config.ts` is the central loader for the chain, public RPCs, contract names, ABI paths, wallet connectors and mobile opening links. Contract addresses are loaded exclusively from `dist/imd-deployment.json` at runtime. The application verifies every configured ABI’s canonical Keccak hash before rendering contract controls, and checks chain ID and deployed code before enabling writes.

The build automatically consumes `.imd/reads/deployment.json` and `.imd/reads/network.json` when present. To bind externally supplied workflow files after building:

```sh
node test/scratch/web/scripts/export.mjs "$PWD" /path/to/deployment.json /path/to/network.json
node test/scratch/web/scripts/check-export.mjs "$PWD" /path/to/deployment.json /path/to/network.json
```

Use the actual workflow handoff, not sample values. The exporter copies `launchId`, `chainId`, `sourceCommit`, `attestationHash`, the complete contract set and optional `poolKey`; it copies `network` and `walletAddChain` without modifying their contents. Only the specified manifest keys are emitted. Each ABI is a raw array and must match the handoff’s Keccak-256 of recursively key-sorted JSON (array order preserved). ABI JSON may come from the pinned handoff export or the accepted implementation in `web/public/abi/`. A hash mismatch fails the export. After any asset change, regenerate and check the manifest; it inventories every other exported file with lowercase SHA-256 hashes and excludes itself.

Without a vetted network file, the page has **no active swap, quote, approval or liquidity action**. The pool’s trade control explains that limitation. This assignment implements ticker governance, payout reads and pool details; it does not supply an unvetted trading route. The fallback public chain configuration is from [Robinhood’s official network documentation](https://docs.robinhood.com/chain/connecting/). The worker’s RPC chain-ID check returned `0x1237` (4663). No private RPC or credential appears in source or export.

### Available flows

- Current king token and beneficiary, reign start/age, ticker totals and cumulative `crownPaid[ticker][native ETH]`. Unknown values are never rendered as zero.
- `openChallenge` with the registry's `requiredBond` (0.01 ETH, or twice the live challenge's bond to displace it during its staking window, offered under the live challenge as "Displace this challenge"), same-symbol candidate validation and explicit beneficiary/slashing explanation. The standing challenger is prefilled only when that contract exists in the handoff; otherwise the visitor enters a real token address.
- `stake` on either side, exact decimal-to-wei conversion, both running stakes, quorum progress, chain-time countdown, 72-hour window and 24-hour timelock. The seven-day reign and three-day failed-challenge cooldown gate opening another challenge.
- Permissionless `finalize`, per-wallet `claim` by historical challenge ID, and `withdrawTreasury` to the address read from the registry. Claims are scoped to CRWN, including challenges older than the current live one.
- `registerKing` only if the CRWN ticker is unregistered; the connected wallet is explicitly shown as the beneficiary in this flow.
- Owner-only, one-time `setRegistry` and `registerPool` setup controls. Visitors see an unconfigured fee-routing notice. Pool registration uses the handoff’s exact key and the brief’s default 100 bps cut. Optional ownership transfer/renunciation remains a direct-contract operation, not a primary page flow.
- A reign timeline from registry state and paged `Crowned` events, with transaction/explorer links. Each page queries 10,000 blocks and exposes its coverage; “Load earlier reigns” requests the preceding range. A public RPC can silently omit old logs, so the page never claims this is a complete archive. Registry state remains authoritative for the current king.
- EIP-6963 wallet discovery, mobile MetaMask/Coinbase/Rabby/Phantom opening links, and Coinbase Smart Wallet. No WalletConnect relay or project ID is required. An unknown-chain switch (4902) offers `wallet_addEthereumChain`, then switches again. Wrong-chain, loading, rejected, pending, confirmed and RPC-error states are explicit.

Every write has a review dialog, simulation before signing, an exact-chain wallet check and a receipt/explorer link. The reviewed request and account are frozen; a changed wallet account cancels that review. Replaced, cancelled, reverted and unresolved receipts have distinct handling. Reads poll every five seconds while the page is active, use public RPCs with connected-wallet fallback, and disable writes on read failure or data older than 20 seconds. A hook registry/ticker mismatch also disables actions. ETH/token amounts use their decimals; USD estimates are deliberately unavailable because no price source was supplied.

### Validation and design records

```sh
npm --prefix test/scratch/web run typecheck
PLAYWRIGHT_BROWSERS_PATH=/tmp/crown-browsers node test/scratch/web/node_modules/playwright/cli.js install chromium webkit
CROWN_ROOT="$PWD" PLAYWRIGHT_BROWSERS_PATH=/tmp/crown-browsers npm --prefix test/scratch/web test
node test/scratch/web/scripts/check-export.mjs "$PWD"
```

Set `CROWN_BROWSER=webkit` to run the same interaction suite in WebKit when its system libraries are available. Browser tests own a bounded local HTTP server and mocked wallet/RPC; they never send real transactions. Mock addresses occur only in test fixtures and are never exported. Unit tests cover wei precision, time boundaries, address rejection and error translation. Export tests verify supplied-handoff/network preservation, ABI binding and detection of a changed asset.

See [DESIGN.md](DESIGN.md) for implemented tokens and components, [validation/README.md](validation/README.md) for the six-domain Better Interface review, test results, corrections and limitations, and [web/NOTICE.md](web/NOTICE.md) for attribution. The share image is a local 1200×630 PNG generated from `web/public/share.svg`; its regeneration script is `web/scripts/render-share.mjs`. Relative Open Graph paths remain appropriate until the publisher assigns a URL.

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

Tests (82 in the recorded seeded worker run; the hostile-beneficiary, displacement, partial-cut and
registration-guard cases were added in the findings revision): `test/CrownRegistry.t.sol` (bond, reign, window, timelock, quorum boundary and tie,
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
  A sweep would need to know when the last staker of a round has claimed, which the pull pattern
  cannot tell without per-round staker bookkeeping, and crediting the remainder at `finalize` is not
  possible either (per-staker floors are only known at claim time). It is documented, bounded and
  checked by the invariant suite rather than hidden.
- Displacing a live challenge costs exactly twice its bond, a chosen rule (see the registry rules);
  the bond ladder is 0.01, 0.02, 0.04 … ETH.
- The cut currency is always native ETH; `registerPool` refuses pools whose `currency0` is not ETH.
  `crownPaid` is keyed by currency anyway, as the brief asks.
- `PAYOUT_GAS` (150,000) is a chosen constant: it caps what a hostile beneficiary can burn inside
  someone else's swap. What it can *do* in that gas is bounded by `payout`'s accounting checks: any
  trace it leaves in the PoolManager rolls its payment back.
- Tests pass with an empty environment and in any order; none reads env vars.
- Tests are not an audit: an independent adversarial review is still needed before funds are at
  stake.
