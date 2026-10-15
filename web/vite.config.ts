import { defineConfig } from "vite";
import { readFile } from "node:fs/promises";
import { resolve, join } from "node:path";

const outDir =
  process.env.CROWN_OUT_DIR || resolve(import.meta.dirname, "../dist");
export default defineConfig({
  base: "./",
  build: { outDir, emptyOutDir: true, sourcemap: false },
  server: { host: "127.0.0.1" },
  plugins: [
    {
      name: "crown-runtime-config-for-dev",
      configureServer(server) {
        server.middlewares.use(async (req, res, next) => {
          const path = (req.url || "").split("?")[0];
          if (
            path !== "/imd-deployment.json" &&
            !/^\/abi\/[A-Za-z0-9_]+\.json$/.test(path || "")
          )
            return next();
          try {
            const bytes = await readFile(join(outDir, path.slice(1)));
            res.setHeader("Content-Type", "application/json");
            res.setHeader("Cache-Control", "no-store");
            res.end(bytes);
          } catch {
            res.statusCode = 503;
            res.end(
              "Build the export first to prepare its deployment configuration.",
            );
          }
        });
      },
    },
  ],
});
