import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import {
  createPublicClient,
  custom,
  encodeAbiParameters,
  keccak256,
  type Address,
  type PublicClient,
  type Abi,
} from "viem";
import { type Runtime, TICKER, NATIVE } from "./config";
import { type King, type Challenge } from "./domain";
export type State = {
  king: King;
  liveId: bigint;
  challenge?: Challenge;
  cooldown: bigint;
  totals: readonly bigint[];
  paid: bigint;
  owner: Address;
  hookRegistry: Address;
  pool?: readonly [boolean, `0x${string}`, number];
  treasury: bigint;
  treasuryAddress: Address;
  balance?: bigint;
  tokenBalance?: bigint;
  decimals: number;
  symbol: string;
  block: bigint;
  timestamp: bigint;
  myKing: bigint;
  myChallenger: bigint;
  bond: bigint;
  requiredBond: bigint;
  quorum: bigint;
  minReign: bigint;
  verified: boolean;
};
export const poolId = (r: Runtime) =>
  r.pool
    ? keccak256(
        encodeAbiParameters(
          [
            { type: "address" },
            { type: "address" },
            { type: "uint24" },
            { type: "int24" },
            { type: "address" },
          ],
          [
            r.pool.currency0,
            r.pool.currency1,
            r.pool.fee,
            r.pool.tickSpacing,
            r.pool.hooks,
          ],
        ),
      )
    : undefined;
export async function readState(
  client: PublicClient,
  r: Runtime,
  account?: Address,
): Promise<State> {
  const registry = r.registry!,
    hook = r.hook!,
    token = r.token!;
  if ((await client.getChainId()) !== r.chain.id)
    throw new Error("The RPC returned the wrong chain. Actions are disabled.");
  const block = await client.getBlock();
  const codes = await Promise.all(
    [registry, hook, token].map((c) =>
      client.getCode({ address: c.address, blockNumber: block.number }),
    ),
  );
  if (codes.some((c) => !c || c === "0x"))
    throw new Error(
      "A launch contract has no code on this chain. Actions are disabled.",
    );
  const read = (
    c: { address: Address; abi: Abi },
    functionName: string,
    args: readonly unknown[] = [],
  ) =>
    client.readContract({
      ...c,
      functionName,
      args,
      blockNumber: block.number,
    });
  const [
    king,
    liveId,
    cooldown,
    totals,
    paid,
    owner,
    hookRegistry,
    treasury,
    decimals,
    symbol,
    bond,
    requiredBond,
    quorum,
    minReign,
    pool,
    balance,
    tokenBalance,
    treasuryAddress,
  ] = await Promise.all([
    read(registry, "king", [TICKER]),
    read(registry, "liveChallenge", [TICKER]),
    read(registry, "cooldownUntil", [TICKER]),
    read(registry, "tickerTotals", [TICKER]),
    read(hook, "crownPaid", [TICKER, NATIVE]),
    read(hook, "owner"),
    read(hook, "registry"),
    read(registry, "treasuryOwed"),
    read(token, "decimals"),
    read(token, "symbol"),
    read(registry, "BOND"),
    read(registry, "requiredBond", [TICKER]),
    read(registry, "QUORUM"),
    read(registry, "MIN_REIGN"),
    r.pool ? read(hook, "pools", [poolId(r)]) : undefined,
    account
      ? client.getBalance({ address: account, blockNumber: block.number })
      : undefined,
    account ? read(token, "balanceOf", [account]) : undefined,
    read(registry, "TREASURY"),
  ]);
  const id = liveId as bigint;
  const [challenge, myKing, myChallenger] =
    id > 0n
      ? await Promise.all([
          read(registry, "challenges", [id]),
          account ? read(registry, "kingStakeOf", [id, account]) : 0n,
          account ? read(registry, "challengerStakeOf", [id, account]) : 0n,
        ])
      : [undefined, 0n, 0n];
  return {
    king: king as King,
    liveId: id,
    challenge: challenge as Challenge | undefined,
    cooldown: cooldown as bigint,
    totals: totals as bigint[],
    paid: paid as bigint,
    owner: owner as Address,
    hookRegistry: hookRegistry as Address,
    treasury: treasury as bigint,
    treasuryAddress: treasuryAddress as Address,
    decimals: Number(decimals),
    symbol: String(symbol),
    bond: bond as bigint,
    requiredBond: requiredBond as bigint,
    quorum: quorum as bigint,
    minReign: minReign as bigint,
    pool: pool as State["pool"],
    balance: balance as bigint | undefined,
    tokenBalance: tokenBalance as bigint | undefined,
    block: block.number,
    timestamp: block.timestamp,
    myKing: myKing as bigint,
    myChallenger: myChallenger as bigint,
    verified: true,
  };
}
export function useCrown(r: Runtime) {
  const client = usePublicClient()!;
  const { address, connector, chainId } = useAccount();
  return useQuery({
    queryKey: ["crown", r.registry?.address, address, chainId],
    enabled: r.ready,
    refetchInterval: 5000,
    refetchIntervalInBackground: false,
    retry: 1,
    queryFn: async () => {
      try {
        return await readState(client, r, address);
      } catch (error) {
        if (!connector || chainId !== r.chain.id) throw error;
        const provider = await connector.getProvider();
        return readState(
          createPublicClient({
            chain: r.chain,
            transport: custom(provider as Parameters<typeof custom>[0]),
          }),
          r,
          address,
        );
      }
    },
  });
}
