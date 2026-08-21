/**
 * M0 spike: Courtyard go/no-go.
 *
 * Known before running: plain curl to courtyard.io returns 403 (bot protection),
 * so any access path needs a real-browser fingerprint. This spike answers:
 *  1. Does a headed Playwright browser get through the bot wall?
 *  2. Does the marketplace SPA call an internal JSON API we can read
 *     (listing prices per card) — and is it usable without auth?
 *  3. Can we search a specific card (set + number + grade) and read its
 *     current listing/floor price?
 *
 * Run:  npm run courtyard -- "charizard base set psa 9"
 * No credentials needed — Courtyard listings are public marketplace pages.
 */
import { chromium } from "playwright";
import { mkdirSync } from "node:fs";

const QUERY = process.argv[2] ?? "charizard base set psa 9";
const STATE_DIR = new URL("../.state/", import.meta.url).pathname;
mkdirSync(STATE_DIR, { recursive: true });

const browser = await chromium.launch({ headless: false });
const page = await browser.newPage();

const apiHits: string[] = [];
page.on("response", async (res) => {
  const ct = res.headers()["content-type"] ?? "";
  if (ct.includes("application/json")) {
    apiHits.push(`${res.status()} ${res.url()}`);
    console.log(`[api] ${res.status()} ${res.url()}`);
  }
});

console.log("[1] Loading courtyard.io (curl got 403 — does a real browser pass?)");
const resp = await page.goto("https://courtyard.io", { waitUntil: "domcontentloaded" });
console.log(`[1] Status: ${resp?.status()}`);

console.log(`[2] Searching marketplace: ${QUERY}`);
await page.waitForTimeout(3_000);
try {
  await page.getByRole("searchbox").or(page.getByPlaceholder(/search/i)).first().fill(QUERY);
  await page.keyboard.press("Enter");
} catch {
  console.log("[2] No obvious searchbox — navigate manually in the headed window (60s)...");
}
await page.waitForTimeout(60_000);
await page.screenshot({ path: STATE_DIR + "courtyard-search.png", fullPage: true });
console.log("[2] Screenshot: .state/courtyard-search.png");

console.log(`\n[3] JSON endpoints observed: ${apiHits.length} (see [api] lines above)`);
console.log("\nGO/NO-GO CHECKLIST — fill in spike/README.md:");
console.log("  [ ] Browser passes bot wall?      [ ] Internal JSON API observed?");
console.log("  [ ] API usable without auth?      [ ] Listing/floor price readable per card+grade?");
await browser.close();
