import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import type { Connector } from "wagmi";
import { type Runtime, OPEN_IN } from "./config";
import { friendly, short } from "./domain";
import { Modal, AddressView } from "./ui";
type Provider = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
};
export async function switchNetwork(
  provider: Provider,
  r: Pick<Runtime, "chain" | "walletAddChain">,
) {
  try {
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: r.walletAddChain.chainId }],
    });
  } catch (e) {
    const error = e as { code?: number; message?: string };
    if (
      error.code !== 4902 &&
      !/unknown chain|unrecognized chain|not added/i.test(error.message ?? "")
    )
      throw e;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [r.walletAddChain],
    });
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: r.walletAddChain.chainId }],
    });
  }
  const actual = await provider.request({ method: "eth_chainId" });
  if (Number(actual) !== r.chain.id)
    throw new Error(
      "Your wallet is still on another network. Switch networks and try again.",
    );
}
const browserMark = (
  <svg
    width="28"
    height="28"
    viewBox="0 0 28 28"
    fill="none"
    aria-hidden="true"
  >
    <rect
      x="2"
      y="4"
      width="24"
      height="20"
      rx="4"
      stroke="currentColor"
      strokeWidth="2"
    />
    <path d="M2 10h24m-8 5h8" stroke="currentColor" strokeWidth="2" />
  </svg>
);
export function Wallet({
  r,
  open,
  setOpen,
}: {
  r: Runtime;
  open: boolean;
  setOpen: (v: boolean) => void;
}) {
  const { address, isConnected, chainId, connector } = useAccount();
  const { connectors, connectAsync, isPending, variables } = useConnect();
  const { disconnect } = useDisconnect();
  const [error, setError] = useState(""),
    [switching, setSwitching] = useState(false),
    [accountOpen, setAccountOpen] = useState(false);
  const mobile =
    /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) &&
    !(window as unknown as { ethereum?: unknown }).ethereum;
  const named = connectors.some(
    (c) => c.type === "injected" && c.id !== "injected",
  );
  const listed = [
    ...connectors.filter((c) => c.type === "injected"),
    ...connectors.filter((c) => c.type !== "injected"),
  ].filter(
    (c) =>
      !(c.id === "injected" && named) && !(mobile && c.type === "injected"),
  );
  const label = (c: Connector) =>
    c.id === "injected"
      ? "Browser wallet"
      : c.id === "coinbaseWalletSDK"
        ? mobile
          ? "Coinbase Smart Wallet"
          : "Coinbase Wallet"
        : c.name;
  useEffect(() => {
    if (isConnected) setOpen(false);
  }, [isConnected, setOpen]);
  async function change() {
    setSwitching(true);
    setError("");
    try {
      await switchNetwork((await connector!.getProvider()) as Provider, r);
    } catch (e) {
      setError(friendly(e));
    } finally {
      setSwitching(false);
    }
  }
  async function connect(c: Connector) {
    setError("");
    try {
      await connectAsync({ connector: c });
      setOpen(false);
      const p = (await c.getProvider()) as Provider;
      if (Number(await p.request({ method: "eth_chainId" })) !== r.chain.id) {
        setSwitching(true);
        await switchNetwork(p, r);
      }
    } catch (e) {
      setError(friendly(e));
    } finally {
      setSwitching(false);
    }
  }
  return (
    <>
      <div className="wallet-control">
        {isConnected && chainId !== r.chain.id ? (
          <button
            className="button primary wallet-button"
            onClick={change}
            disabled={switching}
          >
            {switching ? "Switching…" : `Switch to ${r.chain.name}`}
          </button>
        ) : (
          <button
            className="button wallet-button"
            onClick={() => {
              setError("");
              isConnected ? setAccountOpen(true) : setOpen(true);
            }}
          >
            {isConnected && address ? short(address) : "Connect wallet"}
          </button>
        )}
        {error && !open && (
          <p className="wallet-error" role="alert">
            {error}
            <button className="text-button" onClick={() => setError("")}>
              Dismiss
            </button>
          </p>
        )}
      </div>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Connect a wallet"
      >
        <p className="muted">Choose how to connect to {r.chain.name}.</p>
        <div className="wallet-list">
          {mobile &&
            OPEN_IN.map((w) => (
              <a className="wallet-row" key={w.id} href={w.href(location.href)}>
                <img
                  src={`./wallets/${w.id}.svg`}
                  width="28"
                  height="28"
                  alt=""
                />
                Open in {w.name}
              </a>
            ))}
          {listed.map((c) => (
            <button
              className="wallet-row"
              key={c.uid}
              disabled={isPending || switching}
              onClick={() => connect(c)}
            >
              {c.icon ? (
                <img width="28" height="28" src={c.icon} alt="" />
              ) : c.id === "coinbaseWalletSDK" ? (
                <img
                  width="28"
                  height="28"
                  src="./wallets/coinbase.svg"
                  alt=""
                />
              ) : (
                browserMark
              )}
              <span>
                {label(c)}
                {isPending && variables?.connector === c ? " · Opening…" : ""}
              </span>
            </button>
          ))}
        </div>
        <p role="alert" className="error-text">
          {error}
        </p>
        <p className="small muted">
          On a phone, open this page in your wallet’s browser. Smart Wallet
          availability depends on its supported networks.
        </p>
      </Modal>
      <Modal
        open={accountOpen}
        onClose={() => setAccountOpen(false)}
        title="Connected wallet"
      >
        <AddressView value={address} r={r} label="connected wallet" />
        <p>
          {r.chain.name} · Chain {chainId}
        </p>
        <button
          className="button full"
          onClick={() => {
            disconnect();
            setAccountOpen(false);
          }}
        >
          Disconnect wallet
        </button>
      </Modal>
    </>
  );
}
