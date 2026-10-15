# CROWN interface design

## Overview

CROWN is a ticker governance page for CRWN holders, challengers and the launch owner. The page puts the throne and its action side by side on desktop and in a compact sequence on phones. A dark green throne, a gold crown seal and a restrained serif headline give the registry its identity; the rest is a readable, light utility interface. There is no marketing hero, theme switch or animated counter.

The canonical implementation is `web/src/`; `site/index.html` is a retained earlier prototype. The production export is `dist/`. This document describes the final React application, including the explicit state before a deployment handoff exists.

## Colors

Definitions are in `web/src/styles.css:1`. The page uses one green brand/accent, warm neutral surfaces, and separate error/success text. The darker throne uses its own muted foreground and divider.

| Token / value | Implemented use |
| --- | --- |
| `--page: #f5f4ed` | Page canvas |
| `--surface: #fffef9` | Challenge panel, inputs, buttons and dialogs |
| `--ink: #202d25` | Primary text |
| `--muted: #5f6b62` | Supporting text on light backgrounds |
| `--line: #d4d8cd` | Structural rules and borders |
| `--green: #193d30` | Primary action, brand, throne background, progress |
| `--green-hover: #28533f` | Primary action hover |
| `--gold: #efd594` | Crown seal, crown status, focus on the dark throne |
| `--soft: #e7ebdf` | Selected side and transaction/balance surfaces |
| `--error: #a22d20` | Persistent error text |
| `--success: #276342` | Confirmed/active state text |
| `--focus: #875616` | Two-pixel keyboard focus perimeter on light surfaces |
| `#d3dfd4` / `#587060` | Muted text / divider inside the throne |
| `#60695f` on `#e5e8df` | Disabled text and surface |

Measured solid-color contrast: ink/page **13.01:1**, muted/page **5.06:1**, surface/green **11.87:1**, gold/green **8.34:1**, muted throne text/green **8.72:1**, disabled text/surface **4.60:1**, focus/surface **6.17:1**, error/surface **7.09:1**. These are calculated for the listed pairs; the taste probe also inspected rendered text. Status is always accompanied by text, not color alone.

## Typography

The body uses the system sans-serif stack (`ui-sans-serif`, Apple system, BlinkMacSystemFont, Segoe UI, sans-serif). The main heading and king name use Georgia with Times New Roman/serif fallbacks. Addresses use the system monospace stack. Fonts need no remote request or bundled font file.

The six tokens are 14, 16, 20, 24, 36 and 48 pixels at the default 16-pixel root: `--small`, `--body`, `--sub`, `--section`, `--display`, `--headline`. The headline is 48 pixels on desktop, 36 on mobile, weight 700, line height 1.1 and tracking −0.045em. Section headings are 24 pixels, weight 600, line height 1.25. Body line height is 1.5, explanation copy 1.6. The only requested weights are 400, 600 and 700; platform font availability determines the closest native face.

Amounts and countdowns use tabular numbers. Addresses wrap rather than clip, with a full explorer link and copy action. Inputs use 16-pixel text at normal scale to avoid automatic iOS zoom. No small tracked capitals or uppercase kicker labels are used. CROWN and CRWN retain their proper brand/ticker casing.

## Layout

`styles.css` defines a 1200-pixel outer content width with 32-pixel desktop gutters. The desktop dashboard has columns in a 1.3:1 ratio and a 24-pixel gap. The throne and totals occupy the left column; the challenge panel occupies the right. History/claims and pool details follow, then the rules.

Spacing is built around 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48 and 56 pixels, with larger gaps separating sections. Supporting details use native disclosure controls instead of additional card layers.

At 1000 pixels and below, the dashboard columns become equal and totals become labeled rows. At 700 and below, the layout becomes one column: throne, challenge, totals, history/claims, pool, explanation. Gutters are 20 pixels, reduced to 16 below 360. Header navigation is removed while the brand and wallet control remain. The header can wrap for enlarged text.

On mobile, the throne’s full token/beneficiary details collapse behind “King token & beneficiary”; on desktop they are open. The stake amount and action share a row when two eight-rem minimum columns fit, and stack when they do not. Full addresses remain reachable without horizontal scrolling. Dialogs become bottom sheets with a 90dvh maximum and safe-area bottom inset. There are no fixed controls covering page content.

Observed widths: 320, 390, 760 and 1440 pixels; 200% text enlargement was checked at 320, 390 and 1440. Both the launch-pending challenge action and live staking action appear on the first 390×844 screen. Native browser zoom, physical phones and right-to-left localization were not tested.

## Elevation & Depth

The interface is flat. Surface color and a single border establish the challenge panel; structural dividers separate history, pool and explanation. There are no shadows, gradient text or decorative blur. The crown’s thin inner outline belongs to its SVG/medallion artwork. The dialog backdrop is `#15291fe0`; native modal layering makes the background inert. Inline challenge notices use plain text, avoiding a card nested in the panel.

## Shapes

Panels use the 16-pixel `--radius`. Inputs and buttons use eight-pixel corners; mobile dialogs use twenty-pixel upper corners. Crown seals, timeline marks and pair symbols use circles. Control borders are one pixel. The focus perimeter is two pixels with a four-pixel offset. Buttons have at least a 44–48-pixel target in their primary contexts; inline links and copy controls use smaller spaced targets.

## Components

| Component / source | Purpose and states |
| --- | --- |
| `App.tsx` | Composition, launch-pending state, stale/error gating, current throne, totals and rules. One h1 and one main landmark. |
| `ui.tsx: Crown, Arrow` | Decorative inline SVGs; hidden from assistive technology. |
| `ui.tsx: Modal` | Native dialog with Escape/backdrop/close control, explicit Tab boundary wrapping, focus restoration and scroll lock. |
| `ui.tsx: AddressView` | Full checksummed explorer link, copy button and temporary “Copied” label; no clipped address. |
| `Wallet.tsx` | EIP-6963 wallet list, smart wallet, phone deep links, per-row opening state, rejection recovery, account/disconnect dialog and network switching. |
| `ChallengePanel.tsx` | Candidate field or live stake form; radio side choice, amounts, quorum, phase countdown and finalize control. Field errors are associated with inputs and receive focus. During the staking window the same candidate form is offered under a native `details.displace-details` disclosure ("Displace this challenge") with the registry's required bond, a top hairline (`--line`) and 12-pixel top margin, so the secondary action never competes with staking. |
| `Transaction.tsx` | Frozen review, simulated request, fresh wallet-client/chain checks, per-button pending state, receipt/replacement errors and explorer link. |
| `TransactionFeed.tsx` | Persistent transaction result when the originating form changes phase. Dismissible after settlement; does not overlay content. |
| `History.tsx` | Current reign plus paginated event timeline, explicit block coverage, loading/error/retry states. |
| `Management.tsx` | Historical claims, treasury payout, pool facts, deployed-contract links and one-time owner setup. |
| `domain.ts`, `data.ts`, `config.ts` | Exact values, contract state and configuration. Display styles do not determine eligibility. |

The main action uses the green filled button; wallet and secondary controls use a neutral bordered button or an underlined text action. Hover effects are limited to devices supporting hover. Transitions are 150ms background/transform changes only under `prefers-reduced-motion: no-preference`; there are no infinite animations. Forced colors keep explicit borders and system focus highlighting.

## Do’s and don’ts

- Reuse the existing heading scale, `button`, `field`, `section-head`, `AddressView` and `Modal` patterns. Start an additional utility section from the flat history/claims layout.
- Keep the current state and the action near each other, with the cost, chosen side and potential loss stated before confirmation.
- Keep unknown values visibly unknown. “Not live” must never become a fabricated zero or demo balance.
- Keep financial eligibility in the state/transaction layer. Cosmetic changes must not enable wrong-chain, stale, unverified or premature transactions.
- Preserve full addresses and exact token units. Put additional explanations in native details before introducing another card or overlay.
- Use the shipped local SVGs/PNG. Do not introduce a remote font, image CDN, relay project ID or independent contract-address constant.

Guidance provenance and retained licenses: [web/NOTICE.md](web/NOTICE.md). Review evidence and explicit limitations: [validation/README.md](validation/README.md).
