import { createConfig, http, fallback } from "wagmi";
import { injected, coinbaseWallet } from "wagmi/connectors";
import {
  defineChain,
  isAddress,
  keccak256,
  stringToHex,
  erc20Abi,
  type Abi,
  type Address,
  type Hex,
} from "viem";

export const ERC20_ABI = erc20Abi;
export const TICKER = keccak256(stringToHex("CRWN"));
export const NATIVE = "0x0000000000000000000000000000000000000000" as Address; // Native currency sentinel, never a deployment address.
export const EMPTY_TICKER = `0x${"0".repeat(64)}`;
export const FALLBACK_CHAIN = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url: "https://robinhoodchain.blockscout.com",
    },
  },
};
export type PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};
export type Deployment = {
  version: 1;
  chainId: number;
  launchId?: string;
  sourceCommit?: string;
  attestationHash?: string;
  contracts: {
    name: string;
    address: Address;
    abiHash: string;
    abiPath: string;
  }[];
  assets: { path: string; sha256: string }[];
  poolKey?: PoolKey;
  network?: Record<string, unknown>;
  walletAddChain?: {
    chainId: Hex;
    chainName: string;
    rpcUrls: string[];
    nativeCurrency: { name: string; symbol: string; decimals: number };
    blockExplorerUrls?: string[];
  };
};
export type Runtime = ReturnType<typeof createRuntime>;
export const canonical = (v: unknown): string =>
  JSON.stringify(v, (_, value) =>
    value && typeof value === "object" && !Array.isArray(value)
      ? Object.fromEntries(
          Object.entries(value).sort(([a], [b]) => a.localeCompare(b)),
        )
      : value,
  );
export async function loadDeployment(): Promise<{
  deployment: Deployment;
  abis: Record<string, Abi>;
}> {
  const response = await fetch(
    new URL("imd-deployment.json", document.baseURI),
    { cache: "no-store" },
  );
  if (!response.ok)
    throw new Error(
      "Launch configuration could not be loaded. Reload to try again.",
    );
  const deployment = (await response.json()) as Deployment;
  if (
    deployment.version !== 1 ||
    deployment.chainId !== 4663 ||
    !Array.isArray(deployment.contracts)
  )
    throw new Error(
      "The launch configuration does not match this Robinhood Chain application.",
    );
  const abis: Record<string, Abi> = {};
  for (const c of deployment.contracts) {
    if (
      !isAddress(c.address) ||
      c.address === NATIVE ||
      !/^[a-zA-Z0-9_./-]+\.json$/.test(c.abiPath) ||
      c.abiPath.includes("..") ||
      c.abiPath.startsWith("/")
    )
      throw new Error("The deployment contains an invalid contract binding.");
    const response = await fetch(new URL(c.abiPath, document.baseURI));
    if (!response.ok) throw new Error(`Cannot load the ${c.name} interface.`);
    const abi = await response.json();
    if (
      !Array.isArray(abi) ||
      keccak256(stringToHex(canonical(abi))).slice(2) !== c.abiHash
    )
      throw new Error(`The ${c.name} interface does not match the launch.`);
    abis[c.name] = abi;
  }
  return { deployment, abis };
}
export function createRuntime(
  deployment: Deployment,
  abis: Record<string, Abi>,
) {
  const add = deployment.walletAddChain;
  if (add && Number(add.chainId) !== deployment.chainId)
    throw new Error("The wallet network does not match the deployment chain.");
  const network = deployment.network;
  const suppliedRpc = network?.rpcUrls;
  const urls =
    add?.rpcUrls ??
    (Array.isArray(suppliedRpc)
      ? (suppliedRpc as string[])
      : typeof suppliedRpc === "object" &&
          suppliedRpc &&
          "default" in suppliedRpc
        ? (suppliedRpc as { default: { http: string[] } }).default.http
        : undefined) ??
    FALLBACK_CHAIN.rpcUrls.default.http;
  const explorer =
    add?.blockExplorerUrls?.[0] ??
    (typeof network?.explorer === "string" ? network.explorer : undefined) ??
    FALLBACK_CHAIN.blockExplorers.default.url;
  const chain = defineChain({
    ...FALLBACK_CHAIN,
    id: deployment.chainId,
    name:
      add?.chainName ??
      (typeof network?.name === "string" ? network.name : FALLBACK_CHAIN.name),
    rpcUrls: { default: { http: urls } },
    blockExplorers: { default: { name: "Explorer", url: explorer } },
  });
  const walletAddChain = add ?? {
    chainId: `0x${chain.id.toString(16)}` as Hex,
    chainName: chain.name,
    rpcUrls: urls,
    nativeCurrency: chain.nativeCurrency,
    blockExplorerUrls: [explorer],
  };
  const find = (...names: string[]) => {
    const c = deployment.contracts.find((c) => names.includes(c.name));
    return c ? { ...c, abi: abis[c.name] } : undefined;
  };
  const registry = find("CrownRegistry", "ThroneRegistry"),
    hook = find("CrownHook"),
    token = find("CrownToken"),
    challenger = find("CrownChallengerToken");
  const pool = deployment.poolKey;
  if (
    pool &&
    (pool.fee !== 12500 ||
      pool.tickSpacing !== 60 ||
      !hook ||
      pool.hooks.toLowerCase() !== hook.address.toLowerCase() ||
      pool.currency0 !== NATIVE ||
      (token && pool.currency1.toLowerCase() !== token.address.toLowerCase()))
  )
    throw new Error("The pool key does not match the launch contracts.");
  const wagmi = createConfig({
    chains: [chain],
    multiInjectedProviderDiscovery: true,
    connectors: [
      injected(),
      coinbaseWallet({
        version: "4",
        appName: "CROWN",
        appLogoUrl: new URL("favicon.svg", document.baseURI).href,
        preference: { options: "all", telemetry: false },
      }),
    ],
    transports: {
      [chain.id]: fallback(
        urls.map((url) => http(url, { timeout: 12_000, retryCount: 1 })),
      ),
    },
  });
  return {
    deployment,
    abis,
    registry,
    hook,
    token,
    challenger,
    pool,
    chain,
    walletAddChain,
    wagmi,
    explorer,
    ready: !!(registry && hook && token),
  };
}
export const OPEN_IN = [
  {
    id: "metamask",
    name: "MetaMask",
    href: (url: string) =>
      `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, "")}`,
  },
  {
    id: "coinbase",
    name: "Coinbase Wallet",
    href: (url: string) =>
      `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}`,
  },
  {
    id: "rabby",
    name: "Rabby",
    href: (url: string) =>
      `https://go.rabby.io/mobile/?_cmd=open-dapp&dapp=${encodeURIComponent(url)}`,
  },
  {
    id: "phantom",
    name: "Phantom",
    href: (url: string) =>
      `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}`,
  },
];
