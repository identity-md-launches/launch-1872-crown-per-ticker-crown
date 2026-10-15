import { formatEther, isAddress, parseEther, type Address } from "viem";
export type King = {
  token: Address;
  beneficiary: Address;
  reignStartedAt: bigint;
};
export type Challenge = {
  ticker: `0x${string}`;
  challengerToken: Address;
  challengerBeneficiary: Address;
  openedAt: bigint;
  windowEnd: bigint;
  finalizeAfter: bigint;
  finalized: boolean;
  challengerWon: boolean;
  kingStake: bigint;
  challengerStake: bigint;
  winnerBonus: bigint;
};
export const eth = (n: bigint | undefined) =>
  n === undefined ? "Not live" : formatEther(n);
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
export const date = (n: bigint) =>
  new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "UTC",
  }).format(Number(n) * 1000) + " UTC";
export function duration(seconds: bigint) {
  const s = Number(seconds > 0n ? seconds : 0n);
  const d = Math.floor(s / 86400),
    h = Math.floor((s % 86400) / 3600),
    m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${Math.floor(s % 60)}s`;
}
export function phase(c: Challenge | undefined, now: bigint) {
  return !c
    ? "none"
    : c.finalized
      ? "resolved"
      : now < c.windowEnd
        ? "staking"
        : now < c.finalizeAfter
          ? "timelock"
          : "finalizable";
}
export function amount(value: string) {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(value.trim()))
    throw new Error("Enter an ETH amount with up to 18 decimal places.");
  const n = parseEther(value.trim());
  if (n <= 0n) throw new Error("Enter an amount greater than zero.");
  return n;
}
export function addressInput(value: string) {
  const v = value.trim();
  if (!isAddress(v) || /^0x0{40}$/i.test(v))
    throw new Error("Enter a valid, nonzero token address.");
  return v as Address;
}
export function friendly(error: unknown) {
  const e = error as {
    code?: number;
    shortMessage?: string;
    message?: string;
    cause?: unknown;
    name?: string;
    data?: { errorName?: string };
  };
  const text = [
    e?.shortMessage,
    e?.message,
    e?.data?.errorName,
    e?.cause ? friendly(e.cause) : "",
  ]
    .filter(Boolean)
    .join(" ");
  if (/provider.*not found|no.*provider|ProviderNotFound/i.test(text))
    return "No browser wallet was found. Open this page in your wallet’s browser or choose the Coinbase option.";
  if (/unsupported chain|chain.*not supported/i.test(text))
    return "This wallet does not support Robinhood Chain. Choose another wallet.";
  if (e?.code === 4001 || /rejected|denied|UserRejected/i.test(text))
    return "Request declined in your wallet. Nothing was submitted; try again when ready.";
  const messages: Record<string, string> = {
    ReignTooYoung: "The seven-day minimum reign has not ended.",
    InCooldown: "This ticker is still in its three-day challenge cooldown.",
    ChallengeLive:
      "A challenge is already open. Refresh and stake on that challenge.",
    WrongBond: "Opening a challenge requires exactly 0.01 ETH.",
    WindowClosed:
      "The staking window has closed. Refresh to see the next step.",
    TooEarly: "The 24-hour timelock has not ended.",
    SameToken: "Choose a token different from the current king.",
    NothingToClaim: "This wallet has no unclaimed payout for that challenge.",
    NotFinalized: "Finalize this challenge before claiming.",
    AlreadyFinalized:
      "This challenge has already been finalized. Refresh its state.",
    RegistryAlreadySet: "The hook registry has already been set.",
    PoolAlreadyRegistered: "This pool has already been registered.",
    OwnableUnauthorizedAccount: "Only the hook owner can complete this setup.",
    insufficient:
      "Your wallet needs enough ETH for this action and network gas.",
  };
  for (const [key, value] of Object.entries(messages))
    if (text.toLowerCase().includes(key.toLowerCase())) return value;
  if (/timeout|fetch|network|HTTP|RPC/i.test(text))
    return "The network could not be reached. Check your connection and retry.";
  if (
    error instanceof Error &&
    !("shortMessage" in error) &&
    error.message.length < 200 &&
    !/0x[0-9a-f]{8}/i.test(error.message)
  )
    return error.message;
  return "The transaction could not be completed. Refresh the contract state and try again.";
}
