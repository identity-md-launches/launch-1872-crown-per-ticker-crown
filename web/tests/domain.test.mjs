import { test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
const scratch = await mkdtemp(join(tmpdir(), "crown-domain-"));
const outfile = join(scratch, "domain.mjs");
await build({
  entryPoints: ["src/domain.ts"],
  outfile,
  bundle: true,
  platform: "node",
  format: "esm",
});
const { amount, phase, duration, friendly, addressInput } = await import(
  pathToFileURL(outfile)
);
await rm(scratch, { recursive: true, force: true });
test("ETH input keeps every wei and refuses rounded, zero, negative and exponential amounts", () => {
  assert.equal(amount("0.000000000000000001"), 1n);
  assert.equal(amount(" 0.01 "), 10n ** 16n);
  for (const s of [
    "0",
    "-1",
    "1e3",
    "0.0000000000000000001",
    "1.2.3",
    "Infinity",
    "NaN",
    "",
  ])
    assert.throws(() => amount(s));
});
test("staking and timelock boundaries use strict contract timestamps", () => {
  const c = { windowEnd: 100n, finalizeAfter: 200n, finalized: false };
  assert.equal(phase(undefined, 0n), "none");
  assert.equal(phase(c, 99n), "staking");
  assert.equal(phase(c, 100n), "timelock");
  assert.equal(phase(c, 199n), "timelock");
  assert.equal(phase(c, 200n), "finalizable");
  assert.equal(phase({ ...c, finalized: true }, 200n), "resolved");
});
test("addresses reject a missing destination and empty native sentinel", () => {
  assert.throws(() => addressInput(""));
  assert.throws(() => addressInput("0x" + "0".repeat(40)));
});
test("known reverts and wallet declines are actionable", () => {
  assert.match(friendly({ code: 4001 }), /declined/);
  assert.match(
    friendly({
      message: "execution reverted",
      data: { errorName: "WindowClosed" },
    }),
    /window has closed/,
  );
  assert.match(friendly({ message: "insufficient funds" }), /network gas/);
  assert.equal(duration(-5n), "0m 0s");
});
