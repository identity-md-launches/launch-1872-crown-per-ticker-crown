// Rasterize the project's code-native SVG for social crawlers that cannot render SVG.
import { chromium } from "playwright";
import { readFile } from "node:fs/promises";
const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: 1200, height: 630 },
    deviceScaleFactor: 1,
  });
  await page.setContent(
    `<style>body{margin:0}svg{display:block}</style>${await readFile("public/share.svg", "utf8")}`,
  );
  await page.screenshot({ path: "public/share.png" });
} finally {
  await browser.close();
}
