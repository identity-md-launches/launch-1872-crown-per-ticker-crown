// Dependency/cache writes are confined to disposable scratch; only source and final assets ship.
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
const root = resolve(fileURLToPath(new URL("../..", import.meta.url))),
  stage = join(root, "test/scratch/web");
await mkdir(stage, { recursive: true });
for (const file of [
  "package.json",
  "package-lock.json",
  "tsconfig.json",
  "vite.config.ts",
  "index.html",
  "src",
  "public",
  "scripts",
  "tests",
])
  await cp(join(root, "web", file), join(stage, file), { recursive: true });
const run = (cmd, args, env = {}) => {
  const result = spawnSync(cmd, args, {
    cwd: stage,
    stdio: "inherit",
    env: { ...process.env, ...env },
  });
  if (result.status !== 0) process.exit(result.status || 1);
};
if (!process.argv.includes("--installed"))
  run("npm", [
    "ci",
    "--cache",
    "/tmp/crown-npm-cache",
    "--no-audit",
    "--no-fund",
  ]);
run("npm", ["run", "build"], { CROWN_OUT_DIR: join(root, "dist") });
run("node", ["scripts/export.mjs", root]);
