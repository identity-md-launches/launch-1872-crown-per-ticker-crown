// Run after Vite. All deployment bindings come from the supplied handoff, never from inferred addresses.
import {
  readFile,
  writeFile,
  readdir,
  stat,
  mkdir,
  copyFile,
} from "node:fs/promises";
import { resolve, join, relative } from "node:path";
import { createHash } from "node:crypto";
import { keccak256, stringToHex, isAddress } from "viem";
const root = resolve(process.argv[2] || ".."),
  out = resolve(root, "dist");
const exists = async (p) => !!(await stat(p).catch(() => null));
const canonical = (v) =>
  JSON.stringify(v, (_, value) =>
    value && typeof value === "object" && !Array.isArray(value)
      ? Object.fromEntries(
          Object.entries(value).sort(([a], [b]) => a.localeCompare(b)),
        )
      : value,
  );
const handoffPath = process.argv[3]
  ? resolve(process.argv[3])
  : join(root, ".imd/reads/deployment.json");
const networkPath = process.argv[4]
  ? resolve(process.argv[4])
  : join(root, ".imd/reads/network.json");
const handoff = (await exists(handoffPath))
  ? JSON.parse(await readFile(handoffPath, "utf8"))
  : undefined;
const chain = (await exists(networkPath))
  ? JSON.parse(await readFile(networkPath, "utf8"))
  : undefined;
const manifest = {
  version: 1,
  ...(handoff ? { launchId: handoff.launchId } : {}),
  chainId: handoff?.chainId ?? 4663,
  ...(handoff
    ? {
        sourceCommit: handoff.sourceCommit,
        attestationHash: handoff.attestationHash,
      }
    : {}),
  contracts: [],
  assets: [],
};
if (handoff) {
  for (const field of ["launchId", "sourceCommit", "attestationHash"])
    if (!handoff[field]) throw new Error(`Handoff missing ${field}`);
  if (handoff.chainId !== 4663) throw new Error("Unexpected launch chain");
  for (const c of handoff.contracts) {
    if (
      !isAddress(c.address) ||
      /^0x0{40}$/i.test(c.address) ||
      !/^[0-9a-f]{64}$/.test(c.abiHash)
    )
      throw new Error(`Invalid binding for ${c.name}`);
    const path = `abi/${c.name}.json`;
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(c.name))
      throw new Error("Invalid contract name");
    // Prefer a pinned implementation-derived ABI if supplied; otherwise use this accepted implementation's export.
    const candidates = [
      join(root, ".imd/reads", c.abiPath || path),
      join(root, ".imd/reads/abi", `${c.name}.json`),
      join(out, path),
    ];
    let abi;
    for (const candidate of candidates) {
      if (await exists(candidate)) {
        const data = JSON.parse(await readFile(candidate, "utf8"));
        const value = Array.isArray(data) ? data : data.abi;
        if (
          value &&
          keccak256(stringToHex(canonical(value))).slice(2) === c.abiHash
        ) {
          abi = value;
          break;
        }
      }
    }
    if (!abi)
      throw new Error(
        `No implementation ABI matches ${c.name}'s canonical Keccak hash`,
      );
    await mkdir(join(out, "abi"), { recursive: true });
    await writeFile(join(out, path), JSON.stringify(abi, null, 2) + "\n");
    manifest.contracts.push({
      name: c.name,
      address: c.address,
      abiHash: c.abiHash,
      abiPath: path,
    });
  }
  if (handoff.poolKey) manifest.poolKey = { ...handoff.poolKey };
}
if (chain) {
  manifest.network = chain.network;
  if (chain.walletAddChain) manifest.walletAddChain = chain.walletAddChain;
}
async function inventory(dir) {
  for (const name of (await readdir(dir)).sort()) {
    const p = join(dir, name);
    const s = await stat(p);
    if (s.isDirectory()) await inventory(p);
    else if (name !== "imd-deployment.json") {
      if (s.size > 8388608) throw new Error("Export asset exceeds budget");
      const bytes = await readFile(p);
      manifest.assets.push({
        path: relative(out, p).split("\\").join("/"),
        sha256: createHash("sha256").update(bytes).digest("hex"),
      });
    }
  }
}
await inventory(out);
if (manifest.assets.length > 128) throw new Error("Too many exported assets");
await writeFile(
  join(out, "imd-deployment.json"),
  JSON.stringify(manifest, null, 2) + "\n",
);
console.log(
  `Export manifest: ${manifest.contracts.length} contracts, ${manifest.assets.length} hashed assets${handoff ? "" : " (awaiting launch handoff)"}.`,
);
