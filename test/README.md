# CROWN test contribution

Run offline with the existing pinned compiler and vendored dependencies:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x27da370e51768f0c2b8c6dddefd6cea65c06968db613797d0307b6a6c0cbe16f forge test
```

No RPC, environment changes, FFI, package downloads, or files from `test/scratch/` are required.
The integration uses the vendored Uniswap v4 `PoolManager`, actual CROWN ERC-20 deployments,
permission-correct CREATE2 hook deployment, real liquidity, swaps, and settlement. Setting the
local chain ID to 4663 exercises the requested chain context; it is not a fork or evidence of a
live Robinhood Chain deployment. A live-chain rehearsal is outside this tests-only assignment.

## Coverage

- `CrownRegistryBoundaries.t.sol`: exact bond and one-wei deviations; quorum and strict stake-lead
  boundaries; aggregate versus per-staker rounding; odd-wei slash splits; both possible winners;
  ticker-local cooldowns; minimum reign after a flip; late stakes and early/repeated finalization;
  rejected and reentrant claims; rollback and retry of failed treasury payments. Fuzz properties
  run 1,000 cases each.
- `CrownHook.t.sol`: strengthens the existing buy → challenge → stake → finalize → buy scenario
  with a buy during the final timelock second, early/repeated-finalization failures, distinct tokens
  with the same symbol, byte-exact pool-token and registry-contract identity, and no retained
  assets or ERC-6909 claims. Adds any-length registry replies (96 zero bytes is a well-formed
  "no king"), a beneficiary that exhausts its payout gas, settlement rollback after a fee transfer,
  and multiple pools/tickers. Existing tests also cover rejected ETH, missing registry/king,
  unregistered pools, tokens-only initial liquidity, four swap shapes, callback access control,
  pool setup failures, and LP fee collection.
  The swap rehearsal added by the implementation's fix (`simulateSwap` / `_fillableEth`) is
  attacked directly: price-limited partial fills in all four shapes pay the cut on the ETH the
  pool actually moved (unit tests plus a 1,000-case fuzz over random limits, amounts and shapes);
  an empty pool charges nothing in any shape; a hooked pool after a 1 ETH buy is in the same
  state (price, tick, output, LP fee growth) as a hook-less pool after a 0.99 ETH buy, so the
  rehearsal leaves no trace; and a 1,000-case sweep over the gas forwarded to the swap finds no
  window in which the trade completes while the rehearsal fails and the cut is skipped.
- `invariant/CrownRegistryInvariant.t.sol`: 256 sequences of 96 random actions across two tickers
  and four wallets. An independent model tracks all deposited inputs, both sides' stakes, crowns,
  deadline boundaries, finalizations, claims, treasury debt, and per-ticker totals. Checks escrow
  equals outstanding obligations plus bounded rounding dust, withdrawals match entitlements,
  invalid calls leave state intact, and finished rounds cannot change. Every sequence ends by
  finalizing and draining all available obligations, including payouts from both sides.
- `invariant/CrownHookInvariant.t.sol`: 256 sequences of 96 buys, sells, price-limited partial
  buys and sells, successful challenges, and failed challenges. Checks all four swap shapes, the
  fee for full and partial fills, recipient balance changes, `crownPaid`, fixed token supplies,
  token conservation, zero hook custody, absence of deferred claims, and balanced/locked
  PoolManager settlement. Every sequence ends with at least one partial fill. Registry tests above
  separately randomize individual challenge, stake, time, finalize, and claim operations.

The existing conservation and cut fuzz tests also run 1,000 cases each. Run counts are inline;
no Foundry configuration or implementation files were changed.

## Findings from the previous round, now settled

The previous round reported two implementation defects and one specification conflict. The
implementation author fixed the two defects without being able to run Foundry; this round ran
their tests and added adversarial ones. No open finding remains, so there is no `.imd-findings.json`.

1. **High: fees on unexecuted input — fixed and verified.** `beforeSwap` now rehearses the swap
   through a self-call that always reverts and carries the pool's delta back, and charges on the
   ETH the pool will actually move. Verified by: the author's empty-pool and price-limit tests, the
   partial-fill tests for the other two shapes, a four-shape random-limit fuzz, the empty-pool
   any-shape test, the no-trace equivalence against a hook-less pool, and the gas sweep showing the
   fallback "no cut when the rehearsal fails" cannot be reached by a swap that still completes.
   Observation, not a defect: on a full fill of an ETH-specified order the cut is bps of the order
   (1 ETH in pays 0.01 ETH), while on a partial fill or a token-specified order it is bps of the
   ETH the pool moved (net of the cut). The two bases differ by the cut itself, about 1% relative at
   100 bps. The brief leaves the base open; the tests assert the behaviour exactly as implemented
   and bound the cut between bps of the user's ETH and bps of the pool's ETH in every shape.
2. **Medium: malformed 96-byte registry reply blocked swaps — fixed and verified.** The hook now
   reads the beneficiary word by hand and treats dirty upper bits as a failed read. Verified by the
   author's dirty-word test, and the reply-length fuzz no longer excludes 96 bytes: 96 zero bytes is
   a well-formed "no king" skip; every other length is a failed-read skip; both callbacks proceed.
3. **Specification conflict: unchanged registry token — author's answer accepted.** The brief
   requires a flip to point the registry at the distinct challenger token, so `king(ticker).token`
   must change. "Registry token address byte-identical" is satisfied in the sense the tests assert:
   the hook's registry address, the pool key, the traded `currency1` and the launch token's code are
   byte-identical before and after the dethrone, and the king record changes exactly as specified.

Rounding refunds and winner shares down can leave bounded wei dust in the registry, as already
documented by the implementation. Tests account for that dust explicitly rather than treating it
as another user's refundable stake. No implementation changes are included in this contribution.
