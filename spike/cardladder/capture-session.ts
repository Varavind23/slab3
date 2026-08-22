/**
 * Card Ladder HUMAN-SESSION capture (user decision 2026-08-22: bridge via a
 * human-obtained session while pursuing official API access in parallel).
 *
 * Headless automation is walled by Cloudflare Turnstile. This script opens a
 * REAL, visible browser and hands control to YOU: log in and solve any
 * "verify you are human" check yourself. Once you're on the dashboard, search
 * for a card. The script records:
 *   1. the authenticated session  → .state/cardladder.json  (cookies + storage)
 *   2. the search request+response → worker/test/fixtures/cardladder-search.json
 *
 * That fixture is what lets me finish the Card Ladder adapter (the average-sale
 * field name and query shape). The session is what the adapter rides in prod
 * until it expires and you re-run this.
 *
 * Run:  cd spike && npx tsx cardladder/capture-session.ts
 * Then: log in, solve the human check, search one card, wait for results,
 *       and press Enter in this terminal to save + exit.
 */
import { chromium } from "playwright";
import { mkdirSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const STATE_DIR = new URL("../.state/", import.meta.url).pathname;
const FIXTURE = new URL("../../worker/test/fixtures/cardladder-search.json", import.meta.url).pathname;
mkdirSync(STATE_DIR, { recursive: true });

const browser = await chromium.launch({ headless: false }); // visible ON PURPOSE
const context = await browser.newContext();
const page = await context.newPage();

let lastSearch: unknown = null;
let searchUrl = "";
let searchReqBody: string | undefined;
page.on("request", (r) => {
  if (r.url().includes("search.cardladder.com")) {
    searchUrl = r.url();
    searchReqBody = r.postData() ?? undefined;
  }
});
page.on("response", async (res) => {
  if (res.url().includes("search.cardladder.com")) {
    try {
      lastSearch = await res.json();
      console.log(`  [captured search response ${res.status()}]`);
    } catch {
      /* non-JSON, ignore */
    }
  }
});

console.log("\n=== Card Ladder session capture ===");
console.log("A browser window is opening. In it:");
console.log("  1. Log in (solve any 'verify you are human' check yourself).");
console.log("  2. Land on the dashboard.");
console.log("  3. Search for ONE card (e.g. 'Charizard Base Set') and wait for results.");
console.log("  4. Come back here and press Enter to save + exit.\n");

await page.goto("https://app.cardladder.com/login", { waitUntil: "domcontentloaded" });

await new Promise<void>((resolve) => {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.question("Press Enter once you've logged in AND searched a card... ", () => {
    rl.close();
    resolve();
  });
});

await context.storageState({ path: STATE_DIR + "cardladder.json" });
console.log("✓ session saved: spike/.state/cardladder.json");

if (lastSearch) {
  writeFileSync(FIXTURE, JSON.stringify({ url: searchUrl, requestBody: searchReqBody, response: lastSearch }, null, 2));
  console.log(`✓ search contract saved: worker/test/fixtures/cardladder-search.json`);
  console.log(`  endpoint: ${searchUrl}`);
} else {
  console.log("✗ no search response captured — did the search run? Re-run and search a card before pressing Enter.");
}

await browser.close();
