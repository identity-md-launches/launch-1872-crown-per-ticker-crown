import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { parseAbiItem, type Address, type Hash } from "viem";
import { type Runtime, TICKER } from "./config";
import { type State } from "./data";
import { date, friendly } from "./domain";
import { AddressView, Crown } from "./ui";
type Reign = {
  token: Address;
  beneficiary: Address;
  at: bigint;
  tx: Hash;
  block: bigint;
};
const crowned = parseAbiItem(
  "event Crowned(bytes32 indexed ticker, address indexed token, address indexed beneficiary, uint64 reignStartedAt)",
);
export function History({ r, s }: { r: Runtime; s?: State }) {
  const client = usePublicClient()!;
  const [entries, setEntries] = useState<Reign[]>([]),
    [from, setFrom] = useState<bigint>(),
    [to, setTo] = useState<bigint>(),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  async function load(reset = false) {
    if (!r.registry || !s || busy) return;
    setBusy(true);
    setError("");
    try {
      const end = reset
        ? s.block
        : from !== undefined && from > 0n
          ? from - 1n
          : s.block;
      const start = end > 9999n ? end - 9999n : 0n;
      const logs = await client.getLogs({
        address: r.registry.address,
        event: crowned,
        args: { ticker: TICKER },
        fromBlock: start,
        toBlock: end,
        strict: true,
      });
      const next = logs.map((log) => ({
        token: log.args.token,
        beneficiary: log.args.beneficiary,
        at: log.args.reignStartedAt,
        tx: log.transactionHash,
        block: log.blockNumber,
      }));
      setEntries((old) =>
        [...(reset ? [] : old), ...next]
          .filter(
            (item, index, list) =>
              list.findIndex((e) => e.tx === item.tx) === index,
          )
          .sort((a, b) => (a.at > b.at ? -1 : 1)),
      );
      setFrom(start);
      if (reset || to === undefined) setTo(end);
    } catch (e) {
      setError(friendly(e));
    } finally {
      setBusy(false);
    }
  }
  useEffect(() => {
    if (s && from === undefined) void load(true);
  }, [s?.king.reignStartedAt]);
  const previous = entries.filter((e) => e.at !== s?.king.reignStartedAt);
  return (
    <section className="history-section" id="history">
      <div className="section-head">
        <h2>Reign history</h2>
        {s && (
          <button
            className="text-button"
            onClick={() => load(true)}
            disabled={busy}
          >
            Refresh history
          </button>
        )}
      </div>
      <ol className="timeline">
        <li className="current">
          <span className="timeline-mark">
            <Crown size={18} />
          </span>
          <div>
            <div className="timeline-title">
              <h3>
                {s
                  ? "Current reign"
                  : r.ready
                    ? "No reign to display"
                    : "The first reign awaits"}
              </h3>
              <span className="small muted">
                {s
                  ? date(s.king.reignStartedAt)
                  : r.ready
                    ? "Waiting for registry data"
                    : "Genesis"}
              </span>
            </div>
            {s ? (
              <>
                <AddressView
                  value={s.king.token}
                  r={r}
                  label="current king token"
                />
                <p className="small muted">
                  The beneficiary receives fees from every successful crown
                  payout.
                </p>
              </>
            ) : (
              <p className="muted">
                {r.ready
                  ? "The current reign appears after a successful registry read. Use Refresh to try again."
                  : "The genesis king and its beneficiary appear here after launch."}
              </p>
            )}
          </div>
        </li>
        {previous.map((e, i) => (
          <li key={e.tx}>
            <span className="timeline-mark">{previous.length - i}</span>
            <div>
              <div className="timeline-title">
                <h3>Previous reign</h3>
                <span className="small muted">{date(e.at)}</span>
              </div>
              <AddressView value={e.token} r={r} label="previous king token" />
              <p className="small muted">Beneficiary</p>
              <AddressView
                value={e.beneficiary}
                r={r}
                label="previous beneficiary"
              />
              <a
                className="small"
                href={`${r.explorer}/tx/${e.tx}`}
                target="_blank"
                rel="noreferrer"
              >
                View crowning transaction ↗
              </a>
            </div>
          </li>
        ))}
      </ol>
      {s && (
        <div className="history-controls">
          <p className="small muted">
            {from !== undefined
              ? `Queried blocks ${from.toString()}–${to?.toString()}. `
              : ""}
            Older events may be unavailable on a non-archive RPC. Empty results
            do not prove a complete history.
          </p>
          <button
            className="button"
            disabled={busy || from === 0n}
            onClick={() => load()}
          >
            {busy
              ? "Loading history…"
              : error
                ? "Retry history"
                : "Load earlier reigns"}
          </button>
        </div>
      )}
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}
