# Frontend validation

## Revision of 2026-10-15 (second findings round)

This revision answers one reviewer finding (`.imd-responses.json`): a king's beneficiary with code
could trade on the pool inside its own payout, settling in ERC-6909 claims so the previous `payout`
checks saw nothing, and so block or front-run exact-input buys and exact-output sells. The fix is in
`src/CrownHook.sol` and described in the README ("No beneficiary runs code"): wallets are paid ETH
by `take`, contracts are credited an ERC-6909 native-ETH claim by `mint` and redeem it through the
new `redeem`. The frontend changed only where the contract did: the regenerated `CrownHook` ABI
(`payout` gains `asClaim`; `redeem`, `unlockCallback`, `CrownClaimMinted`, `ClaimRedeemed`,
`ZeroAmount` are new) and one sentence in how-it-works step 01 explaining the claim form of payment.
Everything below was re-run on the final source and the rebuilt `dist/` export.

| Check | Result |
| --- | --- |
| Reproduction | A scratch test following the finding's recipe failed on the starting tree exactly as reported (bounded buy reverted with `slippage`; unbounded buy received 4% less than quoted while `crownPaid` grew). It passes on this tree, and the scenario is now a permanent test (`test_claimsTradingBeneficiaryCannotFrontRunOrBlockABoundedBuy`). |
| `forge build` | Pass with the pinned Solidity 0.8.26 settings. |
| Seeded `forge test` | **88 passed, 0 failed, 0 skipped** (`FOUNDRY_FUZZ_SEED` as given), including the registry and hook invariant suites. |
| Production build and `tsc --noEmit` | Pass (`node web/scripts/build-worker.mjs`; dependencies installed in `test/scratch/web`, export written to root `dist/`). |
| Chromium test run | **12 passed, 0 failed**: seven browser tests, four domain tests, one export test, against the rebuilt export with the regenerated ABI (`CROWN_ROOT` set to the repository root; Playwright's Chromium 1248 installed under the home cache, outside the repository). |
| WebKit test run | Not repeated in this revision; the earlier WebKit run below predates it. |
| Pinned design-critic probe | **16 of 16 passed** on the rebuilt export; output replaced in [taste.json](taste.json). The 390-wide screenshot shows the product ("The CRWN throne"), the wallet control and the "Open challenge" action on the first screen; nothing scrolls sideways at 320, 390 or 1440. |
| Export verification | Pass: **20 assets, 1,556,597 bytes** excluding the manifest; SHA-256 inventory, ABI bindings, allowed manifest keys and relative base verified after the final build (`web/scripts/check-export.mjs`). |

Better Interface review of the one copy change (writing domain): the sentence sits in the
how-it-works step it explains, uses plain words ("credited the cut as a native-ETH claim in the pool
manager", "redeems it in its own transaction") and names no code. No layout, typography, colour,
component or accessibility change was made. Limitations unchanged from the previous revision: no
live-chain interaction (the launch has no handoff yet, so every contract action stays disabled
with the "Awaiting launch" state), and a contract beneficiary's `redeem` has no control on the page
(it is an owner-of-claims action for a multisig or splitter, documented in the README; the page's
connected wallets are code-less accounts paid in ETH directly).

## Revision of 2026-10-15 (findings round)

This revision answers six reviewer findings (`.imd-responses.json`): a hostile beneficiary that could
block every swap, the sham-challenge lock on the ticker, the owner-chosen registry and unused default
cut, the all-or-nothing cut on a short PoolManager, floor-rounding dust, and `registerPool` accepting
squatted tickers. The contract changes (`src/CrownHook.sol`, `src/CrownRegistry.sol`) are described in
the README; the frontend changed only where the contracts did. Everything below was re-run on the
final source and the rebuilt `dist/` export.

| Check | Result |
| --- | --- |
| `forge build` | Pass with the pinned Solidity 0.8.26 settings. |
| Seeded `forge test` | **82 passed, 0 failed, 0 skipped** in the delivered tree (83 with the reviewer's proof copied under `test/scratch/`, which now passes). New: hostile beneficiary on all four swap shapes, `payout` self-call guard, partial cut on a short manager, registry code-hash binding, king-owns-pool registration guard, challenge displacement; the registry invariant handler models the displacement bond rule. |
| Reviewer proof `Proof_3cf0264adc30.t.sol` | Failed on the starting tree with `CurrencyNotSettled()`; **passes** on this tree. |
| Production build and `tsc --noEmit` | Pass (`node web/scripts/build-worker.mjs`). |
| Chromium test run | **12 passed, 0 failed**: seven browser tests, four domain tests, one export test, against the rebuilt export with the regenerated ABIs (the fixture now serves `requiredBond` and the two new `Challenge` fields). |
| WebKit test run | Not repeated in this revision (no WebKit runtime on this worker); the earlier WebKit run below predates the revision. |
| Pinned design-critic probe | **16 of 16 passed** on the rebuilt export; output replaced in [taste.json](taste.json). The 390-wide screenshot shows the product, the wallet control and the "Open challenge" action on the first screen. |
| Export verification | Pass: **20 assets, 1,554,436 bytes** excluding the manifest; SHA-256 inventory, ABI bindings, allowed manifest keys and relative base verified after the final build. |

Frontend changes in this revision, reviewed against the six Better Interface domains:

- `web/src/data.ts`, `web/src/domain.ts`: read the registry's `requiredBond(ticker)`; the `Challenge`
  type carries `bond` and `displacedBy`; the `WrongBond` and `ChallengeLive` translations now say what
  the bond must be and when the slot is closed (writing: the direction sits beside the control).
- `web/src/ChallengePanel.tsx`: the open-challenge control sends `requiredBond` instead of a fixed
  0.01 ETH, is disabled while `requiredBond` is zero (live challenge past its window), and during the
  staking window the same form is offered under a native disclosure "Displace this challenge
  (… ETH bond)" whose review text states the doubled bond, the full refunds of the displaced
  challenge and the new window (UI: native details, no new card; accessibility: the disclosure is a
  real `summary` with a 44-pixel hit area; layout: it stacks under the stake form, nothing scrolls
  sideways at 320 or 390 in the probe).
- `web/src/App.tsx`: how-it-works step 02 and the rules disclosure explain displacement in plain
  English.
- `web/public/abi/*.json` and `dist/abi/*.json`: regenerated from the new Foundry build (`CrownHook`
  gains `payout`, the code-hash immutables and the new errors; `CrownRegistry`/`ThroneRegistry` gain
  `requiredBond`, `ChallengeDisplaced` and the struct fields).

Not exercised in this revision: a real wallet on Robinhood Chain (no deployment handoff yet), a
displacement signed by a real wallet (the mocked fixture validates the sent value against
`requiredBond` only through the open-challenge path), and WebKit. These are limitations of this
worker, not failed checks.

Recorded 2026-10-15 (first round) against the then-final `web/` source and root `dist/` export; the revision section above supersedes its counts. The accepted Solidity implementation, dependencies and Foundry configuration were preserved. This record concerns the implemented ticker frontend and local checks, not deployment or an independent contract audit.

## Results

| Check | Result |
| --- | --- |
| `forge build` | Pass with the repository's pinned Solidity 0.8.26 settings; existing lint warnings remain. |
| Seeded `forge test` | **78 passed, 0 failed, 0 skipped**, across seven suites. Includes exact-wei registry math and the actual local Uniswap v4 buy → challenge → stake → finalize → buy/sell integration. |
| Production build | Pass: TypeScript followed by Vite, relative base `./`, local assets, no backend dependency. |
| Separate `tsc --noEmit` | Pass. |
| Chromium test run | **12 passed, 0 failed**: seven browser tests, four domain tests, one export test. |
| WebKit test run | **12 passed, 0 failed**: the same suite in a second rendering engine. |
| Pinned design-critic probe | **16 of 16 passed**; complete output in [taste.json](taste.json). |
| Export verification | Pass: **20 assets, 1,549,117 bytes** excluding the small manifest; all SHA-256 hashes, ABI bindings, allowed manifest keys and relative asset paths checked. |
| Browser resource/console inspection | Final pending-launch page: no console errors or warnings, no missing resources, only local requests before wallet use. Mocked interaction tests also assert no unexpected external requests. |

The Foundry seed was `0x27da370e51768f0c2b8c6dddefd6cea65c06968db613797d0307b6a6c0cbe16f`. No Solidity, build configuration, dependency library, ignore file or existing package manifest was changed. Frontend dependencies and browser installations were kept in disposable scratch or temporary directories, outside the delivered source/export.

Vite reports a nonfatal warning for the approximately 639 kB minified main chunk (197 kB gzip). The complete export is about 1.55 MB, including the wallet SDK chunks, ABI files and local images. No dependency archives, source maps, package-manager caches or `node_modules` are included.

## Meaningful interaction coverage

The browser suite serves the production export from `/preview/`, rather than a development server. Its EIP-6963 provider and JSON-RPC fixture use the shipped implementation ABIs. Fixture addresses and state exist only in test code and are never included in the published configuration.

- Connect/disconnect, wallet names, absent-provider recovery and mobile links for MetaMask, Coinbase, Rabby and Phantom. The four marks load locally and the links preserve the encoded current URL.
- Wrong-chain gating and the full unknown-chain sequence: rejected switch with code 4902, `wallet_addEthereumChain`, then another switch. No transaction can proceed on the previous chain.
- Open a challenge with exactly 0.01 ETH; validate the candidate's code, CRWN symbol and distinct address. Reject malformed or current-king addresses before requesting a signature.
- Stake on both sides, preserve decimal precision to the wei, reject invalid amounts, and recover after wallet rejection. The suite checks the exact calldata and value sent to the wallet.
- Close staking at the 72-hour boundary; wait logically through the 24-hour timelock in the fixture; finalize and display the changed king and beneficiary. This advances a mocked timestamp, with no real-time wait or live funds.
- Claim a finalized CRWN challenge, show the claimable amount, and route the treasury action to the address returned by the registry. Owner setup is hidden from other wallets; the owner can set the registry and register the exact pool key.
- Translate a contract simulation revert, handle RPC loss/history failure, allow retry, disable writes on invalid state, and refuse an ABI hash mismatch.
- Modal Escape, Tab/Shift-Tab boundary wrapping and focus return; explicit form labels and field-associated errors. Large balances, expanded addresses, open wallet menus and 200% text enlargement remain within the viewport.

The seven browser cases are supplemented by domain tests for exact ETH parsing, phase boundaries, address validation and friendly errors, plus an export test that preserves a supplied handoff/network and detects altered assets. The receipt replacement/cancellation/timeout handlers and inactive-tab stale-state clock were reviewed in source; the browser suite does not exhaust every possible wallet receipt race.

## Better Interface review

Applied the pinned Better Interface workflow and core principles across all six domains during implementation, then reviewed the final export with the pinned design-critic probe, Chromium, WebKit and source inspection. The implementation's tokens and component rules are in [DESIGN.md](../DESIGN.md); attribution and retained licenses are in [web/NOTICE.md](../web/NOTICE.md).

| Domain | Review and result | Remaining coverage limits |
| --- | --- | --- |
| Accessibility | Landmarks, one h1, skip link, real labels/buttons/radios, dialog focus containment and restoration, visible focus, field errors and status messages. Checked keyboard dismissal/navigation and 200% text enlargement. Reduced motion and forced-color rules inspected. | No screen-reader session, physical assistive device or native browser zoom test. |
| Layout | Rendered at 320, 390, 760 and 1440 wide. No sideways scrolling with long addresses, large balances or open wallet menus. Product, wallet and main action visible in the first 390×844 screen. | No physical phone or exhaustive device matrix. |
| Writing | Costs, bond treatment, loss, quorum, timing, beneficiary and finalization explained beside the relevant action and in review dialogs. Unknown values remain unknown. Launch-pending, wrong-chain, stale and failed states explain recovery. | English only. |
| Typography | Six-size token scale, three weights, heaviest main heading, readable system fonts, tabular amounts and wrapping full addresses. Probe passes size, tracking, casing and hierarchy checks. | Native font rendering varies by platform. |
| Colors | Rendered probe passes text contrast. Solid-color calculations are recorded in DESIGN.md, including 13.01:1 primary text and 5.06:1 muted text on the page. Status uses text as well as color; dark-surface focus is gold. | No physical display calibration or color-vision user study. |
| UI | Explicit connect/switch/review/simulate/sign/receipt flow, persistent transaction result, owner setup, native disclosures, form/error/loading states, local SVGs and metadata. No nested cards, infinite animations or floating content obstruction. | Real wallet passkeys, vendor popups and funded transactions remain untested. |

### Findings fixed before the final build

These locations refer to the delivered source. Each change was followed by the applicable browser checks; the last full build, both interaction suites and probe pass.

| Severity | Finding and source | Fix and evidence |
| --- | --- | --- |
| High | Expanded mobile throne and staking controls pushed the primary action below the first screen; `web/src/App.tsx:134`, `web/src/styles.css:1299`. | Mobile token/beneficiary disclosure and compact responsive stake layout. Pending action ends around y=707; mocked live stake action ends around y=764 in Chromium and y=785 in WebKit, within the 844-pixel viewport. |
| High | Wallet client could retain the old chain immediately after an unknown-chain switch; `web/src/Transaction.tsx:89`. | Obtain a fresh wallet client at confirmation and recheck account/chain. The add-chain → switch → challenge test now completes. |
| Medium | Keyboard navigation could leave the intended focus sequence at a dialog boundary; `web/src/ui.tsx:62`. | Explicit Tab/Shift-Tab wrapping, Escape close and focus restoration. Browser keyboard assertions pass. |
| Medium | Inline challenge notice introduced a card within a card; `web/src/styles.css:1249`. | Use plain inline notice treatment inside the panel. Final probe reports zero nested cards and zero border-plus-shadow combinations. |
| Medium | Invalid amounts and candidates needed a direct field association; `web/src/ChallengePanel.tsx:209`, `web/src/ChallengePanel.tsx:338`. | Persistent descriptive errors, `aria-invalid`/`aria-describedby` and focus on the invalid field. Invalid candidate and amount paths checked. |
| Medium | Wallet SDK attempted optional telemetry before connection; `web/src/config.ts:179`. | Disable optional telemetry in connector preferences. Final network inspection and browser harness show no unsolicited external requests. |
| Low | Focus contrast needed a dedicated treatment on the dark throne; `web/src/styles.css:1356`. | Gold focus outline on that surface, with system Highlight under forced colors. Source and contrast review complete. |

The taste probe reports five smaller secondary targets below its comfortable 44-pixel suggestion; all 14 measured controls meet its minimum target-size/spacing check. Primary buttons remain at least 44 pixels. Inline links and copy controls retain visible spacing and are not a failed check.

### Screenshots

- [Pending launch, 390×844](screenshots/pending-390.png): actual final static export, first screen.
- [Pending launch, 1440×1000](screenshots/pending-1440.png): actual final static export, desktop.
- [Mocked staking, 390×844](screenshots/mock-staking-390.png): fixture state, not evidence of a live deployment or transaction.
- [WebKit wallet picker, 390×844](screenshots/webkit-wallet-390.png): mobile viewport in the WebKit test engine, not a photograph of a phone.

## Deployment and live-chain limitations

Neither `.imd/reads/deployment.json` nor `.imd/reads/network.json` was supplied. `dist/imd-deployment.json` therefore declares chain 4663 and an empty contract set, inventories all other exported files, and contains no fabricated deployment identifiers or addresses. The app loads that same file at runtime and fails closed on invalid ABI/configuration. Conditional handoff/network copying was validated with isolated test fixtures; there is no actual workflow handoff to attest here.

The public Robinhood network information is documented in the README. The worker's chain-ID read returned 4663. There was no live application-address code check, funded swap, stake, challenge, finalization, receipt, fee-recipient flip or Sourcify verification because no deployed application addresses were supplied. The actual fee-recipient flip is covered by the local Foundry integration test, while frontend transaction behavior is covered with mocked responses. These checks are distinct.

Trading and liquidity are disabled with an explanation: no vetted Uniswap address block was supplied, and this page implements ticker governance and pool information. It does not guess a router, request token approvals or send swaps. Coinbase Smart Wallet's real chain support, passkey creation and vendor service availability were not exercised. Mobile deep-link structure was validated, but wallet-app launch on physical phones was not.

Reign history discloses queried block ranges and offers earlier pages. An RPC may silently omit historical logs; this frontend cannot certify completeness of the event archive. Current registry state is fetched separately. An HTTPS publication URL is still needed for a public wallet-ready site; relative Open Graph image paths can be made absolute by the publisher after naming without inventing a deployment URL. Regenerate the manifest if any exported bytes change.

## Reproduce

From the repository root, with Node 24 and the existing Foundry toolchain:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x27da370e51768f0c2b8c6dddefd6cea65c06968db613797d0307b6a6c0cbe16f forge test
node web/scripts/build-worker.mjs
npm --prefix test/scratch/web run typecheck
PLAYWRIGHT_BROWSERS_PATH=/tmp/crown-browsers node test/scratch/web/node_modules/playwright/cli.js install chromium webkit
CROWN_ROOT="$PWD" PLAYWRIGHT_BROWSERS_PATH=/tmp/crown-browsers npm --prefix test/scratch/web test
CROWN_ROOT="$PWD" CROWN_BROWSER=webkit PLAYWRIGHT_BROWSERS_PATH=/tmp/crown-browsers npm --prefix test/scratch/web test
node test/scratch/web/scripts/check-export.mjs "$PWD"
```

WebKit requires the platform libraries listed by Playwright. On this worker missing libraries were downloaded and extracted under `/tmp` and exposed through the browser process's library path; no machine configuration or dependency archive is delivered. The run recorded above succeeded after that runtime setup.

While the pinned read inputs remain available, the design probe command is:

```sh
PLAYWRIGHT_BROWSERS_PATH=/tmp/crown-browsers IMD_PLAYWRIGHT="$PWD/test/scratch/web/node_modules/playwright/index.mjs" node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste
```

The pinned inputs and scratch outputs are removed by the submission workflow; the source tests, selected screenshots and final probe result here remain part of the deliverable. The final bundle audit includes accepted tracked files, new source, lockfile, documentation, screenshots and export, and excludes disposable dependencies/caches at every depth. The 356 candidate files total approximately **4.82 MB uncompressed** (a check-only compressed archive is approximately 1.33 MB), below the 8,388,608-byte submission limit. No submodule, dependency/cache directory, environment file or unnecessary archive is included. All five source/export ABI arrays equal their accepted Foundry build outputs. `git diff --check` passes.
