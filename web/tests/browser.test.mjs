import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, mkdir } from "node:fs/promises";
import { resolve, join, extname } from "node:path";
import { chromium, webkit } from "playwright";
import {
  encodeFunctionResult,
  decodeFunctionData,
  encodeErrorResult,
  encodeEventTopics,
  encodeAbiParameters,
  keccak256,
  stringToHex,
  parseEther,
} from "viem";

// These addresses exist only in the mocked browser/RPC fixture. They are never exported in dist.
const engine = process.env.CROWN_BROWSER === "webkit" ? webkit : chromium;
const A = {
  registry: "0x1111111111111111111111111111111111111111",
  hook: "0x2222222222222222222222222222222222222222",
  token: "0x3333333333333333333333333333333333333333",
  challenger: "0x4444444444444444444444444444444444444444",
  account: "0x5555555555555555555555555555555555555555",
  beneficiary: "0x6666666666666666666666666666666666666666",
};
const zero = "0x" + "0".repeat(40),
  empty = "0x" + "0".repeat(64),
  ticker = keccak256(stringToHex("CRWN")),
  hex = (n) => "0x" + BigInt(n).toString(16),
  hash = "0x" + "a".repeat(64),
  blockHash = "0x" + "b".repeat(64);
const root = resolve(process.env.CROWN_ROOT || ".."),
  dist = join(root, "dist"),
  shots = join(
    root,
    "test/scratch/interactions",
    process.env.CROWN_BROWSER || "chromium",
  );
const canonical = (v) =>
  JSON.stringify(v, (_, x) =>
    x && typeof x === "object" && !Array.isArray(x)
      ? Object.fromEntries(
          Object.entries(x).sort(([a], [b]) => a.localeCompare(b)),
        )
      : x,
  );
const abis = {};
for (const name of [
  "CrownRegistry",
  "CrownHook",
  "CrownToken",
  "CrownChallengerToken",
])
  abis[name] = JSON.parse(
    await readFile(join(dist, "abi", name + ".json"), "utf8"),
  );
const contracts = Object.entries({
  CrownRegistry: A.registry,
  CrownHook: A.hook,
  CrownToken: A.token,
  CrownChallengerToken: A.challenger,
}).map(([name, address]) => ({
  name,
  address,
  abiHash: keccak256(stringToHex(canonical(abis[name]))).slice(2),
  abiPath: `abi/${name}.json`,
}));
const poolKey = {
  currency0: zero,
  currency1: A.token,
  fee: 12500,
  tickSpacing: 60,
  hooks: A.hook,
};
const bodyOf = async (req) => {
  let data = "";
  for await (const chunk of req) data += chunk;
  return data;
};
function fixture() {
  return {
    time: 1800000000n,
    reign: 1800000000n - 8n * 86400n,
    block: 1000000n,
    live: 0n,
    challengeCount: 0n,
    c: undefined,
    king: A.token,
    beneficiary: A.beneficiary,
    paid: parseEther("1.245"),
    kingEver: 0n,
    challengerEver: 0n,
    flips: 0n,
    hookRegistry: A.registry,
    registered: true,
    treasury: 0n,
    claimed: false,
    txs: [],
    simulationError: "",
    rpcError: false,
    historyFail: false,
  };
}
function block(s) {
  return {
    number: hex(s.block),
    hash: blockHash,
    parentHash: blockHash,
    nonce: "0x0000000000000000",
    sha3Uncles: blockHash,
    logsBloom: "0x" + "0".repeat(512),
    transactionsRoot: blockHash,
    stateRoot: blockHash,
    receiptsRoot: blockHash,
    miner: zero,
    difficulty: "0x0",
    totalDifficulty: "0x0",
    extraData: "0x",
    size: "0x100",
    gasLimit: hex(30000000),
    gasUsed: "0x0",
    timestamp: hex(s.time),
    transactions: [],
    uncles: [],
    baseFeePerGas: "0x1",
    mixHash: blockHash,
  };
}
function abiFor(to) {
  return to.toLowerCase() === A.registry
    ? abis.CrownRegistry
    : to.toLowerCase() === A.hook
      ? abis.CrownHook
      : abis.CrownToken;
}
function readResult(s, to, f, args) {
  const reads = {
    king: () => ({
      token: s.king,
      beneficiary: s.beneficiary,
      reignStartedAt: s.reign,
    }),
    liveChallenge: () => s.live,
    cooldownUntil: () => 0n,
    tickerTotals: () => [
      s.challengeCount,
      s.flips,
      s.kingEver,
      s.challengerEver,
    ],
    crownPaid: () => s.paid,
    owner: () => A.account,
    registry: () => s.hookRegistry,
    treasuryOwed: () => s.treasury,
    TREASURY: () => "0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57",
    decimals: () => 18,
    symbol: () => "CRWN",
    name: () => "Crown Demo",
    BOND: () => parseEther("0.01"),
    QUORUM: () => parseEther("0.05"),
    MIN_REIGN: () => 7n * 86400n,
    pools: () => [true, s.registered ? ticker : empty, 100],
    balanceOf: () => parseEther("123456789.123456789123456789"),
    kingStakeOf: () => s.c?.kingStake ?? 0n,
    challengerStakeOf: () => s.c?.challengerStake ?? 0n,
    challenges: () =>
      s.c ?? {
        ticker: empty,
        challengerToken: zero,
        challengerBeneficiary: zero,
        openedAt: 0n,
        windowEnd: 0n,
        finalizeAfter: 0n,
        finalized: false,
        challengerWon: false,
        kingStake: 0n,
        challengerStake: 0n,
        winnerBonus: 0n,
      },
    claimable: () =>
      s.c?.finalized && !s.claimed
        ? s.c.challengerStake + (s.c.kingStake * 8n) / 10n + s.c.winnerBonus
        : 0n,
    poolManager: () => A.hook,
  };
  if (reads[f]) return reads[f]();
  if (s.simulationError)
    throw {
      code: 3,
      message: "execution reverted",
      data: encodeErrorResult({
        abi: abis.CrownRegistry,
        errorName: s.simulationError,
        args:
          s.simulationError === "TooEarly" ? [s.c?.finalizeAfter ?? 0n] : [],
      }),
    };
  if (f === "openChallenge") return s.challengeCount + 1n;
  return undefined;
}
function apply(s, tx) {
  const abi = abiFor(tx.to),
    { functionName: f, args } = decodeFunctionData({ abi, data: tx.data });
  const value = BigInt(tx.value || 0);
  s.txs.push({ f, args, value });
  s.block++;
  if (f === "openChallenge") {
    s.challengeCount++;
    s.live = s.challengeCount;
    s.c = {
      ticker,
      challengerToken: args[1],
      challengerBeneficiary: A.account,
      openedAt: s.time,
      windowEnd: s.time + 72n * 3600n,
      finalizeAfter: s.time + 96n * 3600n,
      finalized: false,
      challengerWon: false,
      kingStake: 0n,
      challengerStake: value,
      winnerBonus: 0n,
    };
    s.challengerEver += value;
  }
  if (f === "stake") {
    if (args[1] === 0) {
      s.c.kingStake += value;
      s.kingEver += value;
    } else {
      s.c.challengerStake += value;
      s.challengerEver += value;
    }
  }
  if (f === "finalize") {
    s.c.finalized = true;
    s.c.challengerWon =
      s.c.challengerStake > s.c.kingStake &&
      s.c.challengerStake + s.c.kingStake >= parseEther("0.05");
    s.live = 0n;
    s.c.winnerBonus = s.c.kingStake / 10n;
    s.treasury = s.c.kingStake / 10n;
    if (s.c.challengerWon) {
      s.king = s.c.challengerToken;
      s.beneficiary = s.c.challengerBeneficiary;
      s.reign = s.time;
      s.flips++;
    }
  }
  if (f === "claim") s.claimed = true;
  if (f === "withdrawTreasury") s.treasury = 0n;
  if (f === "setRegistry") s.hookRegistry = args[0];
  if (f === "registerPool") s.registered = true;
}
function rpc(s, method, params = []) {
  if (s.rpcError)
    throw { code: -32000, message: "RPC temporarily unavailable" };
  if (method === "eth_chainId") return "0x1237";
  if (method === "eth_getBlockByNumber") return block(s);
  if (method === "eth_blockNumber") return hex(s.block);
  if (method === "eth_getCode") return "0x60006000";
  if (method === "eth_getBalance")
    return hex(parseEther("99.987654321987654321"));
  if (method === "eth_gasPrice") return "0x1";
  if (method === "eth_estimateGas") return "0x100000";
  if (method === "eth_getTransactionCount") return "0x0";
  if (method === "eth_call") {
    const [tx] = params;
    const abi = abiFor(tx.to),
      { functionName, args } = decodeFunctionData({ abi, data: tx.data });
    const result = readResult(s, tx.to, functionName, args);
    return encodeFunctionResult({ abi, functionName, result });
  }
  if (method === "eth_getLogs") {
    if (s.historyFail)
      throw { code: -32000, message: "historical logs unavailable" };
    const topics = encodeEventTopics({
      abi: abis.CrownRegistry,
      eventName: "Crowned",
      args: { ticker, token: s.king, beneficiary: s.beneficiary },
    });
    return [
      {
        address: A.registry,
        topics,
        data: encodeAbiParameters([{ type: "uint64" }], [s.reign]),
        blockNumber: hex(s.block),
        transactionHash: hash,
        transactionIndex: "0x0",
        blockHash,
        logIndex: "0x0",
        removed: false,
      },
    ];
  }
  if (method === "mock_sendTransaction") {
    apply(s, params[0]);
    return hash;
  }
  if (method === "eth_getTransactionReceipt")
    return {
      transactionHash: hash,
      transactionIndex: "0x0",
      blockHash,
      blockNumber: hex(s.block),
      from: A.account,
      to: A.registry,
      cumulativeGasUsed: "0x1000",
      gasUsed: "0x1000",
      contractAddress: null,
      logs: [],
      logsBloom: "0x" + "0".repeat(512),
      status: "0x1",
      effectiveGasPrice: "0x1",
      type: "0x2",
    };
  throw { code: -32601, message: `Unhandled fixture method: ${method}` };
}
async function serverFor(s) {
  const server = createServer(async (req, res) => {
    try {
      if (req.url === "/rpc") {
        const json = JSON.parse(await bodyOf(req));
        const handle = (x) => {
          try {
            return {
              jsonrpc: "2.0",
              id: x.id,
              result: rpc(s, x.method, x.params),
            };
          } catch (e) {
            return {
              jsonrpc: "2.0",
              id: x.id,
              error: {
                code: e.code || -32000,
                message: e.message || String(e),
                data: e.data,
              },
            };
          }
        };
        res.setHeader("Content-Type", "application/json");
        res.end(
          JSON.stringify(Array.isArray(json) ? json.map(handle) : handle(json)),
        );
        return;
      }
      const path = decodeURIComponent((req.url || "").split("?")[0]);
      const relative = path.replace(/^\/preview\//, "");
      if (path.includes("..") || !path.startsWith("/preview/")) {
        res.writeHead(404).end();
        return;
      }
      const file = join(dist, relative || "index.html");
      const data = await readFile(file);
      res.setHeader(
        "Content-Type",
        {
          ".html": "text/html",
          ".js": "text/javascript",
          ".css": "text/css",
          ".json": "application/json",
          ".svg": "image/svg+xml",
        }[extname(file)] || "application/octet-stream",
      );
      res.end(data);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}
async function setup(
  browser,
  s,
  { configured = true, chainId = "0x1237", mobile = false, wallet = true } = {},
) {
  const { server, origin } = await serverFor(s);
  const context = await browser.newContext({
    viewport: mobile
      ? { width: 390, height: 844 }
      : { width: 1440, height: 1000 },
    ...(mobile
      ? {
          userAgent:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
        }
      : {}),
  });
  let page;
  try {
    page = await context.newPage();
  } catch (error) {
    await context.close();
    server.close();
    throw error;
  }
  const errors = [];
  const externalRequests = [];
  page.on("request", (request) => {
    if (request.url().startsWith("http") && !request.url().startsWith(origin))
      externalRequests.push(request.url());
  });
  page.on("pageerror", (e) => errors.push(e.message));
  if (configured)
    await page.route("**/imd-deployment.json", (route) =>
      route.fulfill({
        json: {
          version: 1,
          chainId: 4663,
          contracts,
          assets: [],
          poolKey,
          network: { name: "Robinhood Chain", rpcUrls: [origin + "/rpc"] },
          walletAddChain: {
            chainId: "0x1237",
            chainName: "Robinhood Chain",
            rpcUrls: [origin + "/rpc"],
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            blockExplorerUrls: ["https://robinhoodchain.blockscout.com"],
          },
        },
      }),
    );
  if (wallet)
    await page.addInitScript(
      ({ origin, chainId, account }) => {
        let chain = chainId,
          connected = false,
          known = chainId === "0x1237";
        const listeners = {};
        window.__walletCalls = [];
        window.__rejectNext = false;
        const provider = {
          on: (event, cb) => (listeners[event] ??= []).push(cb),
          removeListener: (event, cb) =>
            (listeners[event] = (listeners[event] ?? []).filter(
              (x) => x !== cb,
            )),
          request: async ({ method, params }) => {
            window.__walletCalls.push({ method, params });
            if (
              window.__rejectNext &&
              (method === "eth_requestAccounts" ||
                method === "eth_sendTransaction")
            ) {
              window.__rejectNext = false;
              throw Object.assign(new Error("User rejected request"), {
                code: 4001,
              });
            }
            if (method === "eth_accounts") return connected ? [account] : [];
            if (method === "eth_requestAccounts") {
              connected = true;
              return [account];
            }
            if (method === "eth_chainId") return chain;
            if (method === "wallet_switchEthereumChain") {
              if (!known)
                throw Object.assign(new Error("Unknown chain"), { code: 4902 });
              chain = params[0].chainId;
              for (const cb of listeners.chainChanged ?? []) cb(chain);
              return null;
            }
            if (method === "wallet_addEthereumChain") {
              known = true;
              return null;
            }
            if (method === "wallet_getCapabilities") return {};
            if (method === "wallet_requestPermissions") return [];
            if (method === "wallet_revokePermissions") {
              connected = false;
              return null;
            }
            const response = await fetch(origin + "/rpc", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                jsonrpc: "2.0",
                id: 1,
                method:
                  method === "eth_sendTransaction"
                    ? "mock_sendTransaction"
                    : method,
                params,
              }),
            });
            const json = await response.json();
            if (json.error)
              throw Object.assign(new Error(json.error.message), json.error);
            return json.result;
          },
        };
        window.ethereum = provider;
        window.__changeChain = (value) => {
          chain = value;
          for (const cb of listeners.chainChanged ?? []) cb(chain);
        };
        const announce = () =>
          window.dispatchEvent(
            new CustomEvent("eip6963:announceProvider", {
              detail: {
                info: {
                  uuid: "ffdc4a65-301b-4d9d-b859-d715b92ce16a",
                  name: "Test Wallet",
                  icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"/>',
                  rdns: "test.crown.wallet",
                },
                provider,
              },
            }),
          );
        window.addEventListener("eip6963:requestProvider", announce);
        announce();
      },
      { origin, chainId, account: A.account },
    );
  await page.goto(origin + "/preview/");
  await page.getByRole("heading", { name: "The CRWN throne" }).waitFor();
  return {
    page,
    context,
    server,
    errors,
    externalRequests,
    close: async () => {
      await context.close();
      await new Promise((r) => server.close(r));
    },
  };
}
async function click(page, name) {
  await page.getByRole("button", { name, exact: true }).click();
}
async function connect(page) {
  await click(page, "Connect wallet");
  await click(page, "Test Wallet");
  await page
    .getByRole("button", { name: "0x5555…5555", exact: true })
    .waitFor();
}
async function transact(page, label) {
  await click(page, label);
  await page.getByRole("dialog", { name: label }).waitFor();
  await click(page, "Confirm " + label.toLowerCase());
  try {
    await page
      .getByText(label + " confirmed.", { exact: true })
      .waitFor({ timeout: 8000 });
  } catch (error) {
    console.error(
      "Transaction debug:",
      label,
      await page.locator("body").innerText(),
    );
    throw error;
  }
}
async function refresh(page) {
  await click(page, "Refresh");
  await page.getByRole("button", { name: "Refresh", exact: true }).waitFor();
}
await mkdir(shots, { recursive: true });
test("production export: metadata, static subpath, responsive layout, wallet dialog and keyboard", async () => {
  const browser = await engine.launch({ headless: true });
  const h = await setup(browser, fixture(), { configured: false });
  try {
    const { page } = h;
    for (const width of [320, 390, 760, 1440]) {
      await page.setViewportSize({ width, height: 844 });
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        true,
        `${width}px has overflow`,
      );
      if (width === 390) {
        const box = await page
          .getByRole("button", { name: "Open challenge", exact: true })
          .boundingBox();
        assert.ok(box.y + box.height <= 844, "main action on first screen");
      }
      await page.screenshot({
        path: join(shots, `pending-${width}.png`),
        fullPage: true,
      });
    }
    assert.equal(await page.locator('meta[property="og:image"]').count(), 1);
    assert.equal(
      await page
        .getByRole("button", { name: "Open challenge", exact: true })
        .isDisabled(),
      true,
    );
    await click(page, "Connect wallet");
    await page.getByRole("dialog", { name: "Connect a wallet" }).waitFor();
    assert.equal(
      await page
        .getByRole("button", { name: "Test Wallet", exact: true })
        .count(),
      1,
    );
    assert.equal(await page.getByText("Injected", { exact: true }).count(), 0);
    for (let tab = 0; tab < 6; tab++) {
      await page.keyboard.press("Tab");
      assert.equal(
        await page.evaluate(() =>
          document
            .querySelector("dialog[open]")
            .contains(document.activeElement),
        ),
        true,
      );
    }
    await page.keyboard.press("Escape");
    await page.getByRole("dialog").waitFor({ state: "hidden" });
    assert.equal(
      await page.evaluate(() => document.activeElement.textContent),
      "Connect wallet",
    );
    assert.deepEqual(h.errors, []);
    assert.deepEqual(h.externalRequests, [], "unexpected external request");
  } finally {
    await h.close();
    await browser.close();
  }
});
test("wallet 4902 fallback and full challenge, stake, rejection, timelock, finalize and claim flow", async () => {
  const browser = await engine.launch({ headless: true });
  const s = fixture(),
    h = await setup(browser, s, { chainId: "0x1", mobile: true });
  try {
    const { page } = h;
    await page.getByText("Live contract state", { exact: false }).waitFor();
    await connect(page);
    await page.waitForFunction(
      () =>
        window.__walletCalls.filter(
          (x) => x.method === "wallet_switchEthereumChain",
        ).length >= 2,
    );
    const calls = await page.evaluate(() =>
      window.__walletCalls.map((x) => x.method),
    );
    assert.ok(
      calls.indexOf("wallet_addEthereumChain") >
        calls.indexOf("wallet_switchEthereumChain"),
    );
    await transact(page, "Open challenge");
    assert.equal(s.txs[0].value, parseEther("0.01"));
    await page.getByRole("heading", { name: "Back your side" }).waitFor();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForFunction(
      () => !document.querySelector(".throne-details").open,
    );
    const primary = await page
      .getByRole("button", { name: "Stake on challenger", exact: true })
      .boundingBox();
    console.log("Live mobile primary action:", primary);
    assert.ok(
      primary.y + primary.height <= 844,
      "live stake action on first 390 screen",
    );
    await page.screenshot({ path: join(shots, "live-first-screen-390.png") });
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.getByLabel("Back the king", { exact: true }).check();
    await page.locator('input[name="stake"]').fill("0.02");
    await transact(page, "Stake on king");
    assert.equal(s.c.kingStake, parseEther("0.02"));
    await page.getByLabel("Back challenger", { exact: true }).check();
    await page.locator('input[name="stake"]').fill("0.05");
    await page.evaluate(() => (window.__rejectNext = true));
    await click(page, "Stake on challenger");
    await click(page, "Confirm stake on challenger");
    await page
      .getByRole("alert")
      .filter({ hasText: "Request declined" })
      .waitFor();
    assert.equal(s.txs.length, 2);
    await transact(page, "Stake on challenger");
    assert.equal(s.c.challengerStake, parseEther("0.06"));
    for (const width of [320, 390, 1440]) {
      await page.setViewportSize({ width, height: 844 });
      await page.locator(".throne-details").evaluate((el) => (el.open = true));
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        true,
        `connected ${width}px overflow`,
      );
      await page.screenshot({
        path: join(shots, `staking-${width}.png`),
        fullPage: true,
      });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    s.time = s.c.windowEnd;
    await refresh(page);
    await page.getByText("Timelock", { exact: true }).waitFor();
    assert.equal(
      await page
        .getByRole("button", { name: "Finalize challenge", exact: true })
        .isDisabled(),
      true,
    );
    s.time = s.c.finalizeAfter;
    await refresh(page);
    await page.getByText("Ready to resolve", { exact: true }).waitFor();
    await transact(page, "Finalize challenge");
    assert.equal(s.beneficiary, A.account);
    await page.getByRole("heading", { name: "Current CRWN king" }).waitFor();
    await page.getByLabel("Challenge ID", { exact: true }).fill("1");
    await click(page, "Check payout");
    await page.getByText("Challenger won.", { exact: false }).waitFor();
    await transact(page, "Claim payout");
    assert.equal(s.claimed, true);
    await page.getByText("Treasury payout", { exact: true }).click();
    await transact(page, "Send treasury payout");
    assert.equal(s.treasury, 0n);
    assert.deepEqual(h.errors, []);
    assert.deepEqual(h.externalRequests, [], "unexpected external request");
  } finally {
    await h.close();
    await browser.close();
  }
});
test("bad input, wrong-chain gating, setup permissions and simulation failures", async () => {
  const browser = await engine.launch({ headless: true });
  const s = fixture();
  s.hookRegistry = zero;
  s.registered = false;
  const h = await setup(browser, s);
  try {
    const { page } = h;
    await page.getByText("Live contract state", { exact: false }).waitFor();
    assert.equal(
      await page.getByRole("heading", { name: "Finish crown setup" }).count(),
      0,
    );
    await connect(page);
    await page.getByRole("heading", { name: "Finish crown setup" }).waitFor();
    await transact(page, "Set registry");
    assert.equal(s.hookRegistry, A.registry);
    await transact(page, "Register pool");
    assert.equal(s.registered, true);
    await page.locator('input[name="candidate"]').fill("invalid");
    await click(page, "Open challenge");
    await page
      .getByRole("alert")
      .filter({ hasText: "valid, nonzero" })
      .waitFor();
    assert.equal(s.txs.length, 2);
    await page.locator('input[name="candidate"]').fill(A.token);
    await click(page, "Open challenge");
    await page
      .getByRole("alert")
      .filter({ hasText: "different from the current king" })
      .waitFor();
    await page.locator('input[name="candidate"]').fill(A.challenger);
    await page.evaluate(() => window.__changeChain("0x1"));
    await page
      .getByRole("button", { name: "Switch to Robinhood Chain", exact: true })
      .waitFor();
    assert.equal(
      await page
        .getByRole("button", { name: "Open challenge", exact: true })
        .isDisabled(),
      true,
    );
    await click(page, "Switch to Robinhood Chain");
    await page
      .getByRole("button", { name: "0x5555…5555", exact: true })
      .waitFor();
    s.simulationError = "TooEarly";
    await click(page, "Open challenge");
    await click(page, "Confirm open challenge");
    await page
      .getByRole("alert")
      .filter({ hasText: "timelock has not ended" })
      .waitFor();
    assert.equal(s.txs.length, 2);
    assert.deepEqual(h.errors, []);
    assert.deepEqual(h.externalRequests, [], "unexpected external request");
  } finally {
    await h.close();
    await browser.close();
  }
});
test("RPC failure is visible and blocks all writes; history failure offers retry", async () => {
  const browser = await engine.launch({ headless: true });
  const s = fixture();
  s.historyFail = true;
  const h = await setup(browser, s);
  try {
    const { page } = h;
    await page
      .getByRole("button", { name: "Retry history", exact: true })
      .waitFor();
    s.historyFail = false;
    await click(page, "Retry history");
    await page
      .getByRole("button", { name: "Load earlier reigns", exact: true })
      .waitFor();
    s.rpcError = true;
    await refresh(page);
    await page
      .getByText("Live reads are unavailable. Actions are paused.", {
        exact: true,
      })
      .waitFor();
    assert.equal(
      await page
        .getByRole("button", { name: "Open challenge", exact: true })
        .isDisabled(),
      true,
    );
    s.rpcError = false;
    await refresh(page);
    await page.getByText("Live contract state", { exact: false }).waitFor();
    assert.deepEqual(h.errors, []);
    assert.deepEqual(h.externalRequests, [], "unexpected external request");
  } finally {
    await h.close();
    await browser.close();
  }
});
test("missing provider explains recovery and phone sheet includes all four local wallet marks", async () => {
  const browser = await engine.launch({ headless: true });
  for (const mobile of [false, true]) {
    const h = await setup(browser, fixture(), {
      configured: false,
      mobile,
      wallet: false,
    });
    try {
      const { page } = h;
      await click(page, "Connect wallet");
      if (!mobile) {
        await click(page, "Browser wallet");
        await page
          .getByRole("alert")
          .filter({ hasText: "No browser wallet was found" })
          .waitFor();
      } else {
        for (const name of ["MetaMask", "Coinbase Wallet", "Rabby", "Phantom"])
          assert.equal(
            await page
              .getByRole("link", { name: `Open in ${name}`, exact: true })
              .count(),
            1,
          );
        const rabby = new URL(
          await page
            .getByRole("link", { name: "Open in Rabby", exact: true })
            .getAttribute("href"),
        );
        assert.equal(rabby.searchParams.get("_cmd"), "open-dapp");
        assert.ok(rabby.searchParams.get("dapp").endsWith("/preview/"));
        assert.equal(
          await page
            .locator(".wallet-row img")
            .evaluateAll((images) =>
              images.every((img) => img.complete && img.naturalWidth > 0),
            ),
          true,
        );
        await page.screenshot({
          path: join(shots, "mobile-wallet-picker.png"),
        });
      }
      assert.deepEqual(h.errors, []);
      assert.deepEqual(h.externalRequests, [], "unexpected external request");
    } finally {
      await h.close();
    }
  }
  await browser.close();
});
test("an ABI hash mismatch fails closed before any contract action is available", async () => {
  const browser = await engine.launch({ headless: true });
  const h = await setup(browser, fixture());
  try {
    await h.page.route("**/imd-deployment.json", (route) =>
      route.fulfill({
        json: {
          version: 1,
          chainId: 4663,
          contracts: [{ ...contracts[0], abiHash: "f".repeat(64) }],
          assets: [],
        },
      }),
    );
    await h.page.reload();
    await h.page
      .getByRole("heading", { name: "Unable to load this launch" })
      .waitFor();
    await h.page
      .getByRole("alert")
      .filter({ hasText: "does not match the launch" })
      .waitFor();
    assert.equal(
      await h.page
        .getByRole("button", { name: "Open challenge", exact: true })
        .count(),
      0,
    );
  } finally {
    await h.close();
    await browser.close();
  }
});

test("200% text enlargement reflows without horizontal scrolling", async () => {
  const browser = await engine.launch({ headless: true });
  const h = await setup(browser, fixture(), {
    configured: false,
    mobile: true,
  });
  try {
    for (const width of [320, 390, 1440]) {
      await h.page.setViewportSize({ width, height: 1000 });
      await h.page.evaluate(() => {
        document.documentElement.style.fontSize = "200%";
      });
      assert.equal(
        await h.page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        true,
        `200% text at ${width}px`,
      );
    }
  } finally {
    await h.close();
    await browser.close();
  }
});
