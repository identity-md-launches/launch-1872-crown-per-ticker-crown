import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, cp, readFile, writeFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { keccak256, stringToHex } from "viem";
const canonical = (v) =>
  JSON.stringify(v, (_, x) =>
    x && typeof x === "object" && !Array.isArray(x)
      ? Object.fromEntries(
          Object.entries(x).sort(([a], [b]) => a.localeCompare(b)),
        )
      : x,
  );
const root = resolve(process.env.CROWN_ROOT || "..");
test("export inventory binds every file and preserves a supplied handoff and network exactly", async () => {
  const fixture = await mkdtemp(join(tmpdir(), "crown-export-"));
  try {
    await cp(join(root, "dist"), join(fixture, "dist"), { recursive: true });
    await mkdir(join(fixture, ".imd/reads"), { recursive: true });
    const names = [
      "CrownRegistry",
      "CrownHook",
      "CrownToken",
      "CrownChallengerToken",
    ];
    const contracts = [];
    for (let i = 0; i < names.length; i++) {
      const name = names[i],
        abi = JSON.parse(
          await readFile(join(fixture, "dist/abi", name + ".json"), "utf8"),
        );
      contracts.push({
        name,
        address: "0x" + String(i + 1).repeat(40),
        abiHash: keccak256(stringToHex(canonical(abi))).slice(2),
        abiPath: `abi/${name}.json`,
      });
    }
    const h = {
      version: 1,
      launchId: "test-only-not-a-deployment",
      chainId: 4663,
      sourceCommit: "a".repeat(40),
      attestationHash: "b".repeat(64),
      contracts,
      poolKey: {
        currency0: "0x" + "0".repeat(40),
        currency1: contracts[2].address,
        fee: 12500,
        tickSpacing: 60,
        hooks: contracts[1].address,
      },
    };
    const n = {
      network: {
        name: "Fixture network",
        testnet: false,
        rpcUrls: ["https://example.invalid/rpc"],
        uniswapV4: { poolManager: "0x" + "7".repeat(40) },
      },
      walletAddChain: {
        chainId: "0x1237",
        chainName: "Fixture network",
        rpcUrls: ["https://example.invalid/rpc"],
        nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      },
    };
    await writeFile(
      join(fixture, ".imd/reads/deployment.json"),
      JSON.stringify(h),
    );
    await writeFile(
      join(fixture, ".imd/reads/network.json"),
      JSON.stringify(n),
    );
    execFileSync(process.execPath, ["scripts/export.mjs", fixture]);
    execFileSync(process.execPath, ["scripts/check-export.mjs", fixture]);
    const built = JSON.parse(
      await readFile(join(fixture, "dist/imd-deployment.json"), "utf8"),
    );
    assert.deepEqual(built.contracts, h.contracts);
    assert.deepEqual(built.poolKey, h.poolKey);
    assert.deepEqual(built.network, n.network);
    assert.deepEqual(built.walletAddChain, n.walletAddChain);
    await writeFile(join(fixture, "dist/favicon.svg"), "changed");
    assert.throws(() =>
      execFileSync(process.execPath, ["scripts/check-export.mjs", fixture], {
        stdio: "pipe",
      }),
    );
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});
