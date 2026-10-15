import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { formatUnits } from "viem";
import { type Runtime, NATIVE, TICKER, EMPTY_TICKER } from "./config";
import { useCrown } from "./data";
import { eth, date, duration, friendly } from "./domain";
import { Crown, AddressView, Notice } from "./ui";
import { Wallet } from "./Wallet";
import { TransactionStatus } from "./TransactionFeed";
import { ChallengePanel } from "./ChallengePanel";
import { History } from "./History";
import { Claims, OwnerSetup, Pool } from "./Management";
export default function App({ r }: { r: Runtime }) {
  const [wide, setWide] = useState(
    () => matchMedia("(min-width:701px)").matches,
  );
  useEffect(() => {
    const media = matchMedia("(min-width:701px)");
    const change = () => setWide(media.matches);
    media.addEventListener("change", change);
    return () => media.removeEventListener("change", change);
  }, []);
  const query = useCrown(r);
  const s = query.data;
  const [open, setOpen] = useState(false);
  const [clock, setClock] = useState(Date.now);
  const { address, chainId } = useAccount();
  useEffect(() => {
    const update = () => setClock(Date.now());
    const interval = setInterval(update, 1000);
    window.addEventListener("focus", update);
    document.addEventListener("visibilitychange", update);
    return () => {
      clearInterval(interval);
      window.removeEventListener("focus", update);
      document.removeEventListener("visibilitychange", update);
    };
  }, []);
  const elapsed = BigInt(
    Math.max(0, Math.floor((clock - query.dataUpdatedAt) / 1000)),
  );
  const now = s ? s.timestamp + elapsed : BigInt(Math.floor(Date.now() / 1000));
  const fresh = !!s && !query.isError && elapsed < 20n;
  const wrongRegistry =
    !!s &&
    s.hookRegistry !== NATIVE &&
    s.hookRegistry.toLowerCase() !== r.registry?.address.toLowerCase();
  const wrongTicker =
    !!s?.pool && s.pool[1] !== EMPTY_TICKER && s.pool[1] !== TICKER;
  const healthy = fresh && !wrongRegistry && !wrongTicker;
  const liveKing = s && s.king.token !== NATIVE;
  const configured =
    healthy && s?.hookRegistry !== NATIVE && s?.pool?.[1] === TICKER;
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="site-header">
        <a className="brand" href="#main" aria-label="CROWN home">
          <Crown size={30} />
          <span>CROWN</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#history">The reign</a>
          <a href="#how-it-works">How it works</a>
        </nav>
        <Wallet r={r} open={open} setOpen={setOpen} />
      </header>
      <main id="main">
        <div className="page-heading">
          <div>
            <h1>The CRWN throne</h1>
            <p>One canonical token. A crown anyone can challenge.</p>
          </div>
          <div className="network-label">
            <span className="network-dot" />
            {r.chain.name}
          </div>
        </div>
        <div className="dashboard">
          <section className="throne-panel" aria-labelledby="throne-title">
            <div className="throne-top">
              <div className="state-label light">
                <span className="status-dot" />
                {liveKing
                  ? "Reigning king"
                  : r.ready
                    ? "Throne status"
                    : "Genesis crown"}
              </div>
              <span className="small">
                {liveKing
                  ? `Reigning for ${duration(now - s.king.reignStartedAt)}`
                  : !r.ready
                    ? "Awaiting launch"
                    : s
                      ? "Not crowned"
                      : query.isLoading
                        ? "Reading state"
                        : "Read unavailable"}
              </span>
            </div>
            <div className="throne-identity">
              <div className="crown-seal">
                <Crown size={48} />
              </div>
              <div>
                <h2 id="throne-title">
                  {liveKing
                    ? s.king.token.toLowerCase() ===
                      r.token?.address.toLowerCase()
                      ? "Crown Demo"
                      : "Current CRWN king"
                    : !r.ready
                      ? "Crown Demo"
                      : s
                        ? "Unclaimed throne"
                        : query.isLoading
                          ? "Loading throne"
                          : "Throne unavailable"}
                </h2>
                <p>
                  {liveKing
                    ? "The canonical CRWN token"
                    : !r.ready
                      ? "The launch candidate for CRWN"
                      : s
                        ? "No token holds this ticker yet"
                        : "A verified registry read is required"}
                </p>
              </div>
            </div>
            <details className="throne-details" open={wide}>
              <summary>King token &amp; beneficiary</summary>
              <div className="throne-bottom">
                <div>
                  <span className="small">King token</span>
                  <AddressView
                    value={liveKing ? s.king.token : undefined}
                    r={r}
                    label="king token"
                    compact
                  />
                </div>
                <div>
                  <span className="small">Crown fee beneficiary</span>
                  <AddressView
                    value={liveKing ? s.king.beneficiary : undefined}
                    r={r}
                    label="fee beneficiary"
                    compact
                  />
                </div>
              </div>
              {liveKing && (
                <p className="small throne-date">
                  Crowned {date(s.king.reignStartedAt)}
                </p>
              )}
            </details>
          </section>
          <ChallengePanel
            r={r}
            s={s}
            now={now}
            healthy={healthy}
            connect={() => setOpen(true)}
          />
          <section className="totals" aria-label="Ticker totals">
            <div>
              <span>Crown fees paid</span>
              <strong>
                {s ? eth(s.paid) : "Not live"}
                {s && <small> ETH</small>}
              </strong>
              <p>Paid directly to beneficiaries</p>
            </div>
            <div>
              <span>Challenges opened</span>
              <strong>{s ? s.totals[0].toString() : "Not live"}</strong>
              <p>
                {s
                  ? `${s.totals[1].toString()} successful dethronements`
                  : "Recorded by the registry"}
              </p>
            </div>
            <div>
              <span>Total staked</span>
              <strong>
                {s ? eth(s.totals[2] + s.totals[3]) : "Not live"}
                {s && <small> ETH</small>}
              </strong>
              <p>Both sides, across every reign</p>
            </div>
          </section>
        </div>
        <TransactionStatus r={r} />
        <div className="read-status" aria-live="polite">
          <span className={`status-dot ${healthy ? "online" : ""}`} />
          <span>
            {!r.ready
              ? "Launch pending. No live figures are shown."
              : query.isLoading
                ? "Reading launch contracts…"
                : query.isError
                  ? "Live reads are unavailable. Actions are paused."
                  : !fresh
                    ? "Data is stale. Actions are paused."
                    : `Live contract state · block ${s?.block.toString()}`}
          </span>
          {r.ready && (
            <button
              className="text-button"
              onClick={() => query.refetch()}
              disabled={query.isFetching}
            >
              {query.isFetching ? "Refreshing…" : "Refresh"}
            </button>
          )}
        </div>
        {query.error && <Notice error>{friendly(query.error)}</Notice>}
        {(wrongRegistry || wrongTicker) && (
          <Notice error>
            The hook’s binding differs from this launch. Actions are paused
            until the deployment configuration is corrected.
          </Notice>
        )}
        {s && !configured && !wrongRegistry && !wrongTicker && (
          <Notice>
            Crown fee routing is not configured yet. Swaps can proceed without a
            crown cut until the owner completes setup.
          </Notice>
        )}
        {address && s && (
          <div className="wallet-balances">
            <span>Wallet balance</span>
            <strong>{eth(s.balance)} ETH</strong>
            <strong>
              {s.tokenBalance !== undefined
                ? formatUnits(s.tokenBalance, s.decimals)
                : "Unavailable"}{" "}
              {s.symbol}
            </strong>
            {chainId !== r.chain.id && (
              <span className="error-text">Wrong wallet network</span>
            )}
            <span className="small muted">USD prices unavailable</span>
          </div>
        )}
        <OwnerSetup
          r={r}
          s={s}
          healthy={healthy}
          connect={() => setOpen(true)}
        />
        <div className="details-grid">
          <div>
            <History r={r} s={liveKing ? s : undefined} />
            <Claims
              r={r}
              s={s}
              healthy={healthy}
              connect={() => setOpen(true)}
            />
          </div>
          <Pool r={r} s={s} />
        </div>
        <section className="how-section" id="how-it-works">
          <div className="section-head">
            <h2>How the crown works</h2>
            <span className="small muted">Rules, not rulers</span>
          </div>
          <div className="how-grid">
            <article>
              <span className="step-number">01</span>
              <h3>One ticker, one king</h3>
              <p>
                Each ticker has one king token and one beneficiary.
                Participating pools pay their crown cut directly to that wallet
                during the swap. A beneficiary that is a contract is credited
                the cut as a native-ETH claim in the pool manager instead, and
                redeems it in its own transaction, so no outside code ever runs
                inside somebody else&apos;s swap.
              </p>
            </article>
            <article>
              <span className="step-number">02</span>
              <h3>Put a challenger forward</h3>
              <p>
                After a seven-day reign, anyone can bond 0.01 ETH to challenge
                with a different token. The caller becomes its beneficiary if it
                wins. While a challenge is still taking stakes, a rival can
                displace it by bonding twice its bond.
              </p>
            </article>
            <article>
              <span className="step-number">03</span>
              <h3>Back it with ETH</h3>
              <p>
                Stake on either side for 72 hours. The challenger needs more
                stake than the king and at least 0.05 ETH staked in total. Ties
                keep the king.
              </p>
            </article>
            <article>
              <span className="step-number">04</span>
              <h3>Resolve, then recover</h3>
              <p>
                After a 24-hour timelock, anyone can finalize. Winners recover
                their stake plus rewards; losers recover 80%. Claim your payout
                separately.
              </p>
            </article>
          </div>
          <details className="rules-details">
            <summary>Fee failures, slashing and cooldowns</summary>
            <p>
              Half of the losing side’s 20% slash rewards winning stakers
              proportionally; the other half goes to the fixed treasury. If
              nobody staked on the winning side, the entire slash goes to the
              treasury. Shares round down to whole wei, leaving small dust in
              the registry.
            </p>
            <p>
              A failed challenge starts a three-day cooldown. A successful
              challenge starts a new seven-day reign. There is no admin override
              of the result.
            </p>
            <p>
              A displaced challenge ends at once: nothing is slashed, no
              cooldown starts, and every stake on both sides can be claimed back
              in full. The displacing bond doubles each time, so a sham
              challenge opened to block rivals cannot hold the slot for free.
            </p>
            <p>
              Crown fees are never stored in the hook. If its registry read or
              payment fails, or the pool manager cannot fund the payment, that
              swap skips the cut. The cumulative total counts only successful
              payments. A fresh pool’s first buy may pay no crown cut.
            </p>
          </details>
        </section>
      </main>
      <footer>
        <a className="brand" href="#main">
          <Crown size={22} />
          <span>CROWN</span>
        </a>
        <span>One ticker. One crown.</span>
        <a href="#pool">
          View contracts <span aria-hidden="true">↗</span>
        </a>
      </footer>
    </>
  );
}
