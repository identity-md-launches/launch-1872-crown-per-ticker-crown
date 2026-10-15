import { useState, useRef } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { type Runtime, TICKER, NATIVE, ERC20_ABI } from "./config";
import { type State } from "./data";
import {
  amount,
  addressInput,
  date,
  duration,
  eth,
  phase,
  friendly,
} from "./domain";
import { AddressView, Arrow, Notice } from "./ui";
import { Transaction } from "./Transaction";
export function ChallengePanel({
  r,
  s,
  now,
  healthy,
  connect,
}: {
  r: Runtime;
  s?: State;
  now: bigint;
  healthy: boolean;
  connect: () => void;
}) {
  const { address, chainId } = useAccount();
  const client = usePublicClient()!;
  const [candidate, setCandidate] = useState(r.challenger?.address ?? ""),
    [stakeValue, setStakeValue] = useState("0.01"),
    [side, setSide] = useState<0 | 1>(1);
  const [candidateError, setCandidateError] = useState(""),
    [stakeError, setStakeError] = useState("");
  const candidateRef = useRef<HTMLInputElement>(null),
    stakeRef = useRef<HTMLInputElement>(null);
  const active = s?.challenge;
  const currentPhase = phase(active, now);
  const notCrowned = s?.king.token === NATIVE;
  const ready = r.ready && healthy;
  const eligible = s
    ? now >= s.king.reignStartedAt + s.minReign && now >= s.cooldown
    : false;
  const allowed = ready && (!address || chainId === r.chain.id);
  const boundary = s
    ? s.cooldown > s.king.reignStartedAt + s.minReign
      ? s.cooldown
      : s.king.reignStartedAt + s.minReign
    : 0n;
  const blocked = !r.ready
    ? "Actions open after the launch contracts are published."
    : !healthy
      ? "Waiting for a verified contract read."
      : address && chainId !== r.chain.id
        ? `Switch to ${r.chain.name} with the wallet control.`
        : "";
  const request = (
    functionName: string,
    args: readonly unknown[],
    value?: bigint,
  ) => ({
    address: r.registry!.address,
    abi: r.registry!.abi,
    functionName,
    args,
    value,
  });
  async function checkCandidate() {
    const token = addressInput(candidate);
    if (token.toLowerCase() === s?.king.token.toLowerCase())
      throw new Error("Choose a token different from the current king.");
    const code = await client.getCode({ address: token });
    if (!code || code === "0x")
      throw new Error("That token address has no contract code on this chain.");
    const [symbol, decimals] = await Promise.all([
      client.readContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "symbol",
      }),
      client.readContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "decimals",
      }),
    ]);
    if (symbol.toUpperCase() !== "CRWN")
      throw new Error("Choose a CRWN token for this ticker.");
    if (decimals > 36) throw new Error("This token has unsupported decimals.");
    return token;
  }
  const displacing = !!active && currentPhase === "staking";
  const requiredBond = s?.requiredBond ?? 0n;
  const openForm = (
        <>
          <p className="panel-intro">
            {displacing
              ? `Displace challenge #${s!.liveId.toString()} with a different CRWN token. It ends at once, every stake on both sides is refunded in full, and your challenge starts its own 72-hour window.`
              : "Challenge with a different CRWN token. The opening bond backs your candidate."}
          </p>
          <label className="field">
            {notCrowned ? "King token address" : "Challenger token address"}
            <input
              ref={candidateRef}
              aria-invalid={!!candidateError}
              aria-describedby={candidateError ? "candidate-error" : undefined}
              name="candidate"
              autoComplete="off"
              spellCheck={false}
              value={candidate}
              onChange={(e) => {
                setCandidate(e.target.value);
                setCandidateError("");
              }}
              placeholder="Paste a CRWN contract address"
            />
          </label>
          {candidateError && (
            <p id="candidate-error" role="alert" className="error-text">
              {candidateError}
            </p>
          )}
          <div className="cost-line">
            <span>
              {notCrowned
                ? "Registration"
                : displacing
                  ? "Displacement bond"
                  : "Opening bond"}
            </span>
            <strong>
              {notCrowned
                ? "Gas only"
                : `${eth(s?.requiredBond ?? 10000000000000000n)} ETH`}
            </strong>
          </div>
          <Transaction
            r={r}
            connect={connect}
            primary
            onPrepareError={(error) => {
              setCandidateError(friendly(error));
              candidateRef.current?.focus();
            }}
            label={
              notCrowned
                ? "Register king"
                : displacing
                  ? "Displace challenge"
                  : "Open challenge"
            }
            disabled={
              !allowed || (!notCrowned && (!eligible || requiredBond === 0n))
            }
            summary={
              <>
                <p>
                  {notCrowned
                    ? "Crown this token as the first king of CRWN."
                    : displacing
                      ? `Bond ${eth(requiredBond)} ETH (twice the live challenge’s bond) to displace challenge #${s!.liveId.toString()} and open a new 72-hour challenge. The bond is your challenger stake.`
                      : "Bond 0.01 ETH to open a 72-hour challenge. The bond is your challenger stake."}
                </p>
                <p className="break-all">Token: {candidate}</p>
                <p>
                  Your connected wallet becomes the beneficiary{" "}
                  {notCrowned ? "immediately" : "if the challenger wins"}.{" "}
                  {notCrowned
                    ? "Registration cannot be undone."
                    : "You recover 80% of your bond if it loses."}
                </p>
              </>
            }
            prepare={async () => {
              const token = await checkCandidate();
              return notCrowned
                ? request("registerKing", [TICKER, token, address])
                : request("openChallenge", [TICKER, token], s!.requiredBond);
            }}
          />
          {ready && !notCrowned && !eligible && (
            <p className="small muted">
              {now < s!.cooldown ? "Cooldown ends" : "Minimum reign ends"} in{" "}
              {duration(boundary - now)}. {date(boundary)}.
            </p>
          )}
          <p className="small muted">
            {!ready
              ? "Bond counts toward the challenger’s stake."
              : notCrowned
                ? "The first registration is permanent until a successful challenge."
                : displacing
                  ? "Each displacement doubles the bond, so a sham challenge cannot hold the slot for free."
                  : "The caller receives future crown fees if the challenger wins."}
          </p>
        </>
  );
  return (
    <section
      className={`challenge-panel ${active ? "is-live" : ""}`}
      id="challenge"
      aria-labelledby="challenge-title"
    >
      <div className="section-head">
        <h2 id="challenge-title">
          {active
            ? "Back your side"
            : notCrowned
              ? "Register the king"
              : "Challenge the crown"}
        </h2>
        <span
          className={`state-label ${currentPhase === "staking" ? "active" : ""}`}
        >
          {!r.ready
            ? "Awaiting launch"
            : !s
              ? "State unavailable"
              : active
                ? currentPhase === "staking"
                  ? "Voting open"
                  : currentPhase === "timelock"
                    ? "Timelock"
                    : "Ready to resolve"
                : "No live challenge"}
        </span>
      </div>
      {active ? (
        <>
          <div className="challenge-meta">
            <span>Challenge #{s!.liveId.toString()}</span>
            <span>
              {currentPhase === "staking"
                ? `${duration(active.windowEnd - now)} to stake`
                : currentPhase === "timelock"
                  ? `${duration(active.finalizeAfter - now)} to finalize`
                  : "Anyone can finalize"}
            </span>
          </div>
          <div className="versus">
            <div>
              <span>Current king</span>
              <strong>
                {eth(active.kingStake)} <small>ETH</small>
              </strong>
            </div>
            <div>
              <span>Challenger</span>
              <strong>
                {eth(active.challengerStake)} <small>ETH</small>
              </strong>
            </div>
          </div>
          <progress
            aria-label="Staked toward quorum"
            max={100}
            value={Number(
              ((active.kingStake + active.challengerStake) * 100n) /
                (s?.quorum || 1n),
            )}
          />
          <p className="small muted">
            {eth(active.kingStake + active.challengerStake)} of {eth(s?.quorum)}{" "}
            ETH quorum · bond included
          </p>

          {currentPhase === "staking" ? (
            <>
              <fieldset className="side-picker">
                <legend>Choose a side</legend>
                <label className={side === 0 ? "selected" : ""}>
                  <input
                    type="radio"
                    name="side"
                    checked={side === 0}
                    onChange={() => setSide(0)}
                  />
                  Back the king
                </label>
                <label className={side === 1 ? "selected" : ""}>
                  <input
                    type="radio"
                    name="side"
                    checked={side === 1}
                    onChange={() => setSide(1)}
                  />
                  Back challenger
                </label>
              </fieldset>
              <div className="stake-controls">
                <label className="field">
                  Stake amount{" "}
                  <span className="input-with-unit">
                    <input
                      ref={stakeRef}
                      aria-invalid={!!stakeError}
                      aria-describedby={stakeError ? "stake-error" : undefined}
                      inputMode="decimal"
                      name="stake"
                      value={stakeValue}
                      onChange={(e) => {
                        setStakeValue(e.target.value);
                        setStakeError("");
                      }}
                      autoComplete="off"
                    />
                    <span>ETH</span>
                  </span>
                </label>
                <Transaction
                  r={r}
                  connect={connect}
                  primary
                  onPrepareError={(error) => {
                    setStakeError(friendly(error));
                    stakeRef.current?.focus();
                  }}
                  label={side === 0 ? "Stake on king" : "Stake on challenger"}
                  disabled={!allowed}
                  summary={
                    <>
                      <p>
                        Stake <strong>{stakeValue} ETH</strong> on the{" "}
                        {side === 0 ? "king" : "challenger"} in challenge #
                        {s!.liveId.toString()}.
                      </p>
                      <p>
                        You recover 80% if this side loses. A winning stake is
                        returned in full, with its share of the reward.
                      </p>
                    </>
                  }
                  prepare={() => {
                    const value = amount(stakeValue);
                    if (s?.balance !== undefined && value >= s.balance)
                      throw new Error(
                        "Leave enough ETH in your wallet for network gas.",
                      );
                    return request("stake", [s!.liveId, side], value);
                  }}
                />
              </div>
              {stakeError && (
                <p id="stake-error" role="alert" className="error-text">
                  {stakeError}
                </p>
              )}
              <p className="small muted">
                20% of a losing stake is slashed. Claims open after
                finalization.
              </p>
            </>
          ) : (
            <>
              <p className="small muted">
                {currentPhase === "timelock"
                  ? "Staking is closed. The result can be finalized after the 24-hour timelock."
                  : "The window and timelock have ended. Finalize to resolve the challenge and unlock payouts."}
              </p>
              <Transaction
                r={r}
                connect={connect}
                primary
                label="Finalize challenge"
                disabled={!allowed || currentPhase !== "finalizable"}
                summary={
                  <p>
                    Resolve challenge #{s!.liveId.toString()} by its recorded
                    stakes. The challenger wins only with more stake than the
                    king and at least {eth(s?.quorum)} ETH total.
                  </p>
                }
                prepare={() => request("finalize", [s!.liveId])}
              />
            </>
          )}
          <details className="compact-details">
            <summary>Candidate and timing</summary>
            <p className="small">Challenger token</p>
            <AddressView
              value={active.challengerToken}
              r={r}
              label="challenger token"
            />
            <p className="small">Its beneficiary if it wins</p>
            <AddressView
              value={active.challengerBeneficiary}
              r={r}
              label="challenger beneficiary"
            />
            <p className="small">
              Staking closes {date(active.windowEnd)}.<br />
              Finalization opens {date(active.finalizeAfter)}.
            </p>
          </details>
          {address && (
            <p className="small muted">
              Your stakes: {eth(s?.myKing)} ETH king · {eth(s?.myChallenger)}{" "}
              ETH challenger
            </p>
          )}
          {displacing && (
            <details className="displace-details">
              <summary>
                Displace this challenge ({eth(requiredBond)} ETH bond)
              </summary>
              {openForm}
            </details>
          )}
        </>
      ) : (
        openForm
      )}
      {blocked && <Notice>{blocked}</Notice>}
      <a className="how-link" href="#how-it-works">
        How challenges work <Arrow />
      </a>
    </section>
  );
}
