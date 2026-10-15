import { useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { type Runtime, TICKER, NATIVE, EMPTY_TICKER } from "./config";
import { type State, poolId } from "./data";
import { type Challenge, eth, friendly } from "./domain";
import { AddressView, Notice } from "./ui";
import { Transaction } from "./Transaction";
export function Claims({
  r,
  s,
  healthy,
  connect,
}: {
  r: Runtime;
  s?: State;
  healthy: boolean;
  connect: () => void;
}) {
  const [id, setId] = useState(""),
    [selected, setSelected] = useState<bigint>();
  const { address, chainId } = useAccount();
  const client = usePublicClient()!;
  const lookup = useQuery({
    queryKey: ["claim", r.registry?.address, selected?.toString(), address],
    enabled: !!r.registry && selected !== undefined,
    queryFn: async () => {
      const c = (await client.readContract({
        address: r.registry!.address,
        abi: r.registry!.abi,
        functionName: "challenges",
        args: [selected],
      })) as Challenge;
      if (c.openedAt === 0n || c.ticker !== TICKER)
        throw new Error("No CRWN challenge found for this ID.");
      const value = address
        ? ((await client.readContract({
            address: r.registry!.address,
            abi: r.registry!.abi,
            functionName: "claimable",
            args: [selected, address],
          })) as bigint)
        : undefined;
      return { challenge: c, value };
    },
    retry: false,
  });
  const [error, setError] = useState("");
  const disabled = !healthy || (!!address && chainId !== r.chain.id);
  return (
    <section className="claims-section" id="claims">
      <h2>Recover your stake</h2>
      <p className="muted">
        Claim your refund and any winning reward after a challenge is finalized.
      </p>
      <form
        className="claim-search"
        onSubmit={(e) => {
          e.preventDefault();
          setError("");
          if (!/^[1-9]\d*$/.test(id.trim())) {
            setError("Enter a positive challenge ID.");
            (
              e.currentTarget.elements.namedItem(
                "challenge-id",
              ) as HTMLInputElement
            )?.focus();
            return;
          }
          const next = BigInt(id.trim());
          if (next === selected) void lookup.refetch();
          else setSelected(next);
        }}
      >
        <label className="field">
          Challenge ID
          <input
            aria-invalid={!!error}
            aria-describedby={error ? "claim-id-error" : undefined}
            name="challenge-id"
            inputMode="numeric"
            value={id}
            onChange={(e) => {
              setId(e.target.value);
              setError("");
            }}
            placeholder="e.g. 1"
          />
        </label>
        <button className="button" disabled={!r.ready || lookup.isFetching}>
          {lookup.isFetching ? "Checking…" : "Check payout"}
        </button>
      </form>
      {error && (
        <p id="claim-id-error" className="error-text" role="alert">
          {error}
        </p>
      )}
      {lookup.error && (
        <p className="error-text" role="alert">
          {friendly(lookup.error)}
        </p>
      )}
      {lookup.data && (
        <>
          <p>
            {lookup.data.challenge.finalized
              ? `${lookup.data.challenge.challengerWon ? "Challenger" : "King"} won.`
              : "This challenge is not finalized."}{" "}
            {address
              ? `Available to this wallet: ${eth(lookup.data.value)} ETH.`
              : "Connect your wallet to check its payout."}
          </p>
          <Transaction
            r={r}
            connect={connect}
            label="Claim payout"
            disabled={
              disabled ||
              !lookup.data.challenge.finalized ||
              (!!address && lookup.data.value === 0n)
            }
            summary={
              <p>
                Withdraw {eth(lookup.data.value)} ETH from challenge #
                {selected?.toString()} to your connected wallet. This includes
                both sides if you backed both.
              </p>
            }
            prepare={() => ({
              address: r.registry!.address,
              abi: r.registry!.abi,
              functionName: "claim",
              args: [selected],
            })}
          />
        </>
      )}
      <details className="compact-details">
        <summary>Treasury payout</summary>
        <p className="small muted">
          Anyone can send the accrued treasury share to the registry’s fixed
          treasury. It never goes to the caller.
        </p>
        <AddressView value={s?.treasuryAddress} r={r} label="fixed treasury" />
        <p>
          Available:{" "}
          <strong>
            {eth(s?.treasury)}
            {s ? " ETH" : ""}
          </strong>
        </p>
        <Transaction
          r={r}
          connect={connect}
          label="Send treasury payout"
          disabled={disabled || !s?.treasury}
          summary={
            <>
              <p>
                Send {eth(s?.treasury)} ETH to the treasury fixed in
                CrownRegistry. You pay only the transaction’s gas fee.
              </p>
              <AddressView
                value={s?.treasuryAddress}
                r={r}
                label="fixed treasury"
              />
            </>
          }
          prepare={() => ({
            address: r.registry!.address,
            abi: r.registry!.abi,
            functionName: "withdrawTreasury",
          })}
        />
      </details>
    </section>
  );
}
export function OwnerSetup({
  r,
  s,
  healthy,
  connect,
}: {
  r: Runtime;
  s?: State;
  healthy: boolean;
  connect: () => void;
}) {
  const { address, chainId } = useAccount();
  if (!s || !address || address.toLowerCase() !== s.owner.toLowerCase())
    return null;
  const needsRegistry = s.hookRegistry === NATIVE;
  const needsPool = !s.pool || s.pool[1] === EMPTY_TICKER;
  if (!needsRegistry && !needsPool) return null;
  return (
    <section className="owner-section">
      <h2>Finish crown setup</h2>
      <p className="muted">
        This wallet owns the hook. These settings can each be set once.
      </p>
      <div className="setup-grid">
        <div>
          <h3>1. Connect the registry</h3>
          <AddressView
            value={r.registry?.address}
            r={r}
            label="launch registry"
          />
          <Transaction
            r={r}
            connect={connect}
            label={needsRegistry ? "Set registry" : "Registry set"}
            disabled={!needsRegistry || !healthy || chainId !== r.chain.id}
            summary={
              <>
                <p>Bind the hook permanently to this launch’s registry.</p>
                <AddressView value={r.registry?.address} r={r} />
              </>
            }
            prepare={() => ({
              address: r.hook!.address,
              abi: r.hook!.abi,
              functionName: "setRegistry",
              args: [r.registry!.address],
            })}
          />
        </div>
        <div>
          <h3>2. Register the pool</h3>
          <p className="small muted">
            Bind the launch pool to CRWN with the default 1% crown cut (100
            bps).
          </p>
          <Transaction
            r={r}
            connect={connect}
            label={needsPool ? "Register pool" : "Pool registered"}
            disabled={
              !needsPool ||
              !healthy ||
              !r.pool ||
              !s.pool?.[0] ||
              chainId !== r.chain.id
            }
            summary={
              <p>
                Register the launch’s native ETH pool for CRWN at a permanent 1%
                crown cut. Neither the ticker nor the cut can be changed later.
              </p>
            }
            prepare={() => ({
              address: r.hook!.address,
              abi: r.hook!.abi,
              functionName: "registerPool",
              args: [r.pool, TICKER, 100],
            })}
          />
          {!r.pool && (
            <Notice>The deployment has not supplied its pool key.</Notice>
          )}
        </div>
      </div>
    </section>
  );
}
export function Pool({ r, s }: { r: Runtime; s?: State }) {
  const configured =
    !!s &&
    s.hookRegistry.toLowerCase() === r.registry?.address.toLowerCase() &&
    s.pool?.[1] === TICKER;
  return (
    <section className="pool-section" id="pool">
      <div className="section-head">
        <h2>The launch pool</h2>
        <span className="small muted">Uniswap v4</span>
      </div>
      <div className="pair">
        <span className="pair-icon">Ξ</span>
        <span className="pair-icon crown-pair">♛</span>
        <div>
          <h3>Ether / Crown Demo</h3>
          <p className="small muted">
            Native ETH paired with the genesis CRWN token
          </p>
        </div>
      </div>
      <dl className="pool-facts">
        <div>
          <dt>LP fee</dt>
          <dd>{r.pool ? `${r.pool.fee / 10000}%` : "1.25% at launch"}</dd>
        </div>
        <div>
          <dt>Crown cut</dt>
          <dd>{configured ? `${s!.pool![2] / 100}%` : "Not configured"}</dd>
        </div>
        <div>
          <dt>Tick spacing</dt>
          <dd>{r.pool ? r.pool.tickSpacing : "60 at launch"}</dd>
        </div>
        <div>
          <dt>Fee recipient</dt>
          <dd>
            {configured ? "Current king’s beneficiary" : "Awaiting setup"}
          </dd>
        </div>
      </dl>
      <p className="small muted">
        The pool keeps its original token when the crown changes. Its crown fees
        follow the new beneficiary.
      </p>
      <button className="button full" disabled>
        Trade CRWN
      </button>
      <p className="small muted">
        {!r.deployment.network
          ? "Trading is unavailable until vetted Uniswap routing is supplied with the launch."
          : "This page supports crown governance. Use the launch’s vetted trading interface for swaps."}
      </p>
      <details className="compact-details">
        <summary>Contract addresses</summary>
        {r.deployment.contracts.length === 0 ? (
          <p className="small muted">
            The launch has not published contract addresses.
          </p>
        ) : (
          r.deployment.contracts.map((c) => (
            <div className="contract-row" key={c.name}>
              <span className="small">{c.name}</span>
              <AddressView value={c.address} r={r} label={c.name} />
            </div>
          ))
        )}
        {r.pool && (
          <div className="contract-row">
            <span className="small">Pool ID</span>
            <code className="break-all">{poolId(r)}</code>
          </div>
        )}
      </details>
    </section>
  );
}
