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
  assets or ERC-6909 claims. Adds wrong-length registry replies, a beneficiary that exhausts its
  payout gas, settlement rollback after a fee transfer, and multiple pools/tickers. Existing
  tests also cover rejected ETH, missing registry/king, unregistered pools, tokens-only initial
  liquidity, four swap shapes, callback access control, pool setup failures, and LP fee collection.
- `invariant/CrownRegistryInvariant.t.sol`: 256 sequences of 96 random actions across two tickers
  and four wallets. An independent model tracks all deposited inputs, both sides' stakes, crowns,
  deadline boundaries, finalizations, claims, treasury debt, and per-ticker totals. Checks escrow
  equals outstanding obligations plus bounded rounding dust, withdrawals match entitlements,
  invalid calls leave state intact, and finished rounds cannot change. Every sequence ends by
  finalizing and draining all available obligations, including payouts from both sides.
- `invariant/CrownHookInvariant.t.sol`: 256 sequences of 96 buys, sells, successful challenges,
  and failed challenges. Checks all four swap shapes, fee calculation for full fills, recipient
  balance changes, `crownPaid`, fixed token supplies, token conservation, zero hook custody,
  absence of deferred claims, and balanced/locked PoolManager settlement. Registry tests above
  separately randomize individual challenge, stake, time, finalize, and claim operations.

The existing conservation and cut fuzz tests also run 1,000 cases each. Run counts are inline;
no Foundry configuration or implementation files were changed.

## Findings and limits

The root `.imd-findings.json` contains two reproduced implementation defects and one specification
conflict. The implementation defects have full standalone Foundry proofs, each run and observed
to fail under `test/scratch/` before being embedded in the report. Failing tests are not shipped
as passing assertions or silently skipped.

1. **High: fees on unexecuted input.** `beforeSwap` charges on the requested ETH amount before
   knowing execution volume. With 100 bps and a 1 ETH order, an initialized empty pool charges
   0.01 ETH for zero tokens; a price-limited partial fill also overcharges. Random swap sequences
   cover full fills; empty/partial fills remain failing regression proofs in the report.
2. **Medium: malformed registry responses can block swaps.** A 96-byte response with a dirty
   beneficiary address word passes the length check but reverts during `abi.decode`. This requires
   configuring a nonconforming registry; the shipped `CrownRegistry` returns well-formed data.
   Short/long responses and reverting reads are covered by passing tests; the failing 96-byte case
   is reported rather than asserted as correct.
3. **Specification conflict: unchanged registry token.** The final assignment asks that the
   registry token address remain byte-identical across a dethrone, while the concept requires
   `registry.king(ticker).token` to change to the distinct challenger token. Both cannot hold.
   Tests verify the specified crown replacement and unchanged deployed registry address and pool
   token address. They do not claim that the literal unchanged-king-token criterion is satisfied.

Rounding refunds and winner shares down can leave bounded wei dust in the registry, as already
documented by the implementation. Tests account for that dust explicitly rather than treating it
as another user's refundable stake. No implementation fixes are included in this contribution.
