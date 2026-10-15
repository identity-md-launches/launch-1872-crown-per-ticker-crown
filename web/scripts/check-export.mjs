import { readFile, readdir, stat } from "node:fs/promises";
import { resolve, join, relative } from "node:path";
import { createHash } from "node:crypto";
import { keccak256, stringToHex } from "viem";
const root = resolve(process.argv[2] || ".."),
  out = join(root, "dist");
const canonical = (v) =>
  JSON.stringify(v, (_, x) =>
    x && typeof x === "object" && !Array.isArray(x)
      ? Object.fromEntries(
          Object.entries(x).sort(([a], [b]) => a.localeCompare(b)),
        )
      : x,
  );
const manifest = JSON.parse(
  await readFile(join(out, "imd-deployment.json"), "utf8"),
);
const allowed = new Set([
  "version",
  "launchId",
  "chainId",
  "sourceCommit",
  "attestationHash",
  "contracts",
  "assets",
  "network",
  "walletAddChain",
  "poolKey",
]);
for (const key of Object.keys(manifest))
  if (!allowed.has(key)) throw new Error(`Unknown manifest key: ${key}`);
if (manifest.version !== 1 || manifest.chainId !== 4663)
  throw new Error("Incorrect deployment version or chain");
const files = [];
async function walk(dir) {
  for (const name of await readdir(dir)) {
    const path = join(dir, name);
    const info = await stat(path);
    if (info.isDirectory()) await walk(path);
    else if (name !== "imd-deployment.json") files.push(relative(out, path));
  }
}
await walk(out);
if (files.length !== manifest.assets.length || files.length > 128)
  throw new Error("Incomplete export inventory");
let total = 0;
for (const asset of manifest.assets) {
  if (
    !files.includes(asset.path) ||
    asset.path.includes("..") ||
    asset.path.startsWith("/")
  )
    throw new Error("Invalid asset path");
  const data = await readFile(join(out, asset.path));
  if (createHash("sha256").update(data).digest("hex") !== asset.sha256)
    throw new Error(`Asset changed: ${asset.path}`);
  total += data.length;
}
if (new Set(manifest.assets.map((a) => a.path)).size !== files.length)
  throw new Error("Duplicate asset path");
for (const c of manifest.contracts) {
  const abi = JSON.parse(await readFile(join(out, c.abiPath), "utf8"));
  if (
    !Array.isArray(abi) ||
    keccak256(stringToHex(canonical(abi))).slice(2) !== c.abiHash
  )
    throw new Error(`ABI binding mismatch: ${c.name}`);
}
const exists = async (path) => !!(await stat(path).catch(() => null));
const handoffPath = process.argv[3]
  ? resolve(process.argv[3])
  : join(root, ".imd/reads/deployment.json");
if (await exists(handoffPath)) {
  const h = JSON.parse(await readFile(handoffPath, "utf8"));
  for (const key of [
    "launchId",
    "chainId",
    "sourceCommit",
    "attestationHash",
    "poolKey",
  ])
    if (canonical(h[key]) !== canonical(manifest[key]))
      throw new Error(`Handoff mismatch: ${key}`);
  if (h.contracts.length !== manifest.contracts.length)
    throw new Error("Contract set differs");
  for (const c of h.contracts) {
    const m = manifest.contracts.find((x) => x.name === c.name);
    if (!m || m.address !== c.address || m.abiHash !== c.abiHash)
      throw new Error("Contract binding differs");
  }
}
const networkPath = process.argv[4]
  ? resolve(process.argv[4])
  : join(root, ".imd/reads/network.json");
if (await exists(networkPath)) {
  const n = JSON.parse(await readFile(networkPath, "utf8"));
  for (const key of ["network", "walletAddChain"])
    if (canonical(n[key]) !== canonical(manifest[key]))
      throw new Error(`Network block differs: ${key}`);
}
const html = await readFile(join(out, "index.html"), "utf8");
if (!html.includes("./assets/")) throw new Error("Vite base is not relative");
console.log(
  `PASS: ${files.length} assets, ${total} bytes; SHA-256 inventory, ABI bindings, manifest schema and relative base verified.`,
);
