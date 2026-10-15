import { useState, type ReactNode } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { getWalletClient } from "wagmi/actions";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi, Address, Hash } from "viem";
import { type Runtime } from "./config";
import { friendly } from "./domain";
import { Modal } from "./ui";
import { useTransactionFeed } from "./TransactionFeed";
export type Request = {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
};
export function Transaction({
  r,
  label,
  summary,
  disabled = false,
  prepare,
  primary = false,
  connect,
  onPrepareError,
}: {
  r: Runtime;
  label: string;
  summary: ReactNode;
  disabled?: boolean;
  prepare: () => Request | Promise<Request>;
  primary?: boolean;
  connect: () => void;
  onPrepareError?: (error: unknown) => void;
}) {
  const feed = useTransactionFeed();
  const { address, chainId } = useAccount();
  const client = usePublicClient()!;
  const query = useQueryClient();
  const [reviewAccount, setReviewAccount] = useState<Address>();
  const [reviewSummary, setReviewSummary] = useState<ReactNode>();
  const [review, setReview] = useState(false),
    [pending, setPending] = useState(""),
    [error, setError] = useState(""),
    [hash, setHash] = useState<Hash>(),
    [success, setSuccess] = useState(false),
    [request, setRequest] = useState<Request>();
  async function start() {
    setError("");
    setSuccess(false);
    setHash(undefined);
    if (!address) {
      connect();
      return;
    }
    if (chainId !== r.chain.id) {
      setError(`Switch to ${r.chain.name} using the wallet control.`);
      return;
    }
    try {
      setPending("Checking action…");
      const request = await prepare();
      setRequest(request);
      setReviewSummary(summary);
      setReviewAccount(address);
      setReview(true);
    } catch (e) {
      if (onPrepareError) onPrepareError(e);
      else setError(friendly(e));
    } finally {
      setPending("");
    }
  }
  async function submit() {
    setReview(false);
    if (!request || !address) {
      setError("Your wallet connection is not ready. Reconnect and try again.");
      return;
    }
    if (address !== reviewAccount) {
      setError("Your connected account changed. Review the action again.");
      return;
    }
    let broadcast: Hash | undefined;
    let outcomeKnown = false;
    let replacementReason: string | undefined;
    try {
      setPending("Simulating…");
      const wallet = await getWalletClient(r.wagmi, { chainId: r.chain.id });
      if (wallet.account.address.toLowerCase() !== reviewAccount?.toLowerCase())
        throw new Error("Your account changed. Review the action again.");
      if ((await wallet.getChainId()) !== r.chain.id)
        throw new Error("Switch to Robinhood Chain before confirming.");
      const simulation = await client.simulateContract({
        ...request,
        account: address,
      });
      setPending("Confirm in wallet…");
      if ((await wallet.getChainId()) !== r.chain.id)
        throw new Error("Your wallet changed network. Try again.");
      const tx = await wallet.writeContract({
        ...simulation.request,
        chain: r.chain,
      });
      broadcast = tx;
      setHash(tx);
      feed.update({ label, hash: tx, status: "pending" });
      setPending("Waiting for confirmation…");
      const receipt = await client.waitForTransactionReceipt({
        hash: tx,
        timeout: 120_000,
        onReplaced: ({ reason, transactionReceipt }) => {
          replacementReason = reason;
          broadcast = transactionReceipt.transactionHash;
          setHash(broadcast);
          feed.update({ label, hash: broadcast, status: "pending" });
        },
      });
      outcomeKnown = true;
      if (replacementReason === "cancelled")
        throw new Error("The transaction was cancelled in your wallet.");
      if (replacementReason === "replaced")
        throw new Error(
          "The transaction was replaced with a different action. Follow the transaction link to inspect its result.",
        );
      if (receipt.status !== "success")
        throw new Error(
          "The transaction reverted. No contract changes were applied.",
        );
      setSuccess(true);
      await query.invalidateQueries();
      feed.update({ label, hash: receipt.transactionHash, status: "success" });
    } catch (e) {
      const message =
        broadcast && !outcomeKnown
          ? "Confirmation could not be checked. Follow the transaction link before submitting again."
          : friendly(e);
      if (broadcast)
        feed.update({
          label,
          hash: broadcast,
          status: "error",
          message,
        });
      setError(message);
    } finally {
      setPending("");
    }
  }
  return (
    <div className="transaction">
      <button
        className={`button full ${primary ? "primary" : ""}`}
        disabled={disabled || !!pending}
        onClick={start}
        aria-busy={!!pending}
      >
        {pending || label}
      </button>
      <div className="tx-feedback" aria-live="polite">
        {success && <p className="success-text">Confirmed.</p>}
        {hash && (
          <a href={`${r.explorer}/tx/${hash}`} target="_blank" rel="noreferrer">
            View transaction ↗
          </a>
        )}
      </div>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
      <Modal open={review} onClose={() => setReview(false)} title={label}>
        <div className="review-summary">{reviewSummary}</div>
        <p className="small muted">
          Network: {r.chain.name}. Your wallet will show the network gas fee
          before you confirm.
        </p>
        <button className="button primary full" onClick={submit}>
          Confirm {label.toLowerCase()}
        </button>
      </Modal>
    </div>
  );
}
