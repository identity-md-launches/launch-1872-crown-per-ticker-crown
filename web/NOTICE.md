# Guidance and asset attribution

The interface applies Jakub Krehel’s Better Interface, pinned commit `267330e1adfc66a718fb65fa6918c1f06d0a689e` (MIT). DESIGN.md follows the documentation method adapted from Paul Bakaus’s Impeccable, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8` (Apache-2.0). Both original notices and licenses are retained in [licenses/BetterInterface.txt](licenses/BetterInterface.txt). The CROWN implementation and design document are new, assignment-specific work; they do not reproduce the reference guide.

Wallet UX also applies the supplied Austin Griffith ethskills frontend guide, commit `06ea4efa0807` (MIT); see [licenses/EthFrontendUX.txt](licenses/EthFrontendUX.txt).

The MetaMask, Rabby and Phantom SVG marks are from [RainbowKit’s wallet connectors](https://github.com/rainbow-me/rainbowkit/tree/main/packages/rainbowkit/src/wallets/walletConnectors), retrieved 2026-10-15. The Coinbase mark comes from the pinned wallet-connectors reference. See [licenses/WalletMarks.txt](licenses/WalletMarks.txt). These marks identify wallet providers; no affiliation is implied. CROWN’s crown, seal, favicon and share graphic are code-native SVG assets created for this page.

The Rabby opening link is based on its own [universal-link handler](https://github.com/RabbyHub/rabby-mobile/blob/develop/apps/mobile/src/hooks/universalLink.ts) and [production path definition](https://github.com/RabbyHub/rabby-mobile/blob/develop/apps/mobile/src/constant/universalLink.ts), retrieved 2026-10-15: `/mobile/?_cmd=open-dapp&dapp=<encoded-page-URL>`.

Runtime package notices are included in `public/NOTICE.txt` and the static export. Package versions and integrity hashes are recorded in `package-lock.json`.
