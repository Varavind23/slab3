/**
 * M0 spike: Card Ladder go/no-go.
 *
 * Answers, with a REAL account:
 *  1. Can we script login (email/password)? Is there 2FA, and of what kind?
 *  2. Does the session persist via cookies (storageState) across runs?
 *  3. Can we search a card and read a market-average price off the page,
 *     or does the app fetch JSON we can read directly from network traffic?
 *  4. Do we get bot-challenged (Cloudflare/hCaptcha) at human-pace usage?
 *
 * Run:  CL_EMAIL=you@x.com CL_PASSWORD=... npm run cardladder -- "1999 Pokemon Base Set Charizard PSA 9"
 * Never commit credentials. storageState is written to .state/ (gitignored).
 */
import { chromium } from "playwright";
import { mkdirSync, existsSync } from "node:fs";

const EMAIL = process.env.CL_EMAIL;
const PASSWORD = process.env.CL_PASSWORD;
const QUERY = process.argv[2] ?? "1999 Pokemon Base Set Charizard PSA 9";
const STATE_DIR = new URL("../.state/", import.meta.url).pathname;
const STATE_FILE = STATE_DIR + "cardladder.json";

if (!EMAIL || !PASSWORD) {
  console.error("Set CL_EMAIL and CL_PASSWORD env vars (never commit them).");
  process.exit(1);
}

mkdirSync(STATE_DIR, { recursive: true });

// Recon findings (2026-08-21): the real app is at app.cardladder.com (marketing
// site www.cardladder.com/login 404s). Login form = input#email + input#password
// + "Submit". Auth backend is FIREBASE (googleapis.com/identitytoolkit) — so the
// production adapter can authenticate against Firebase directly and call the JSON
// API with the ID token, no DOM scraping. This spike confirms login end-to-end
// and captures the price endpoint the app calls for a searched card.
const browser = await chromium.launch({ headless: false }); // headed: watch for 2FA/captcha
const context = existsSync(STATE_FILE)
  ? await browser.newContext({ storageState: STATE_FILE })
  : await browser.newContext({
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
      viewport: { width: 1280, height: 900 },
    });
const page = await context.newPage();

// Log JSON traffic — Card Ladder API + Firebase auth. This is where prices live.
page.on("response", async (res) => {
  const ct = res.headers()["content-type"] ?? "";
  const url = res.url();
  if (ct.includes("json") && /cardladder|identitytoolkit|firebase/i.test(url)) {
    console.log(`[api] ${res.status()} ${url.split("?")[0]}`);
  }
});

console.log("[1] Loading app.cardladder.com/login ...");
await page.goto("https://app.cardladder.com/login", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(6_000);

const loggedIn = await page.locator("#email").count().then((n) => n === 0);
if (!loggedIn) {
  console.log("[2] Logging in via Firebase email/password (watch window for 2FA/captcha)");
  await page.fill("#email", EMAIL);
  await page.fill("#password", PASSWORD);
  await page.getByRole("button", { name: /^submit$/i }).first().click();
  // Wait for either navigation away from /login or a 2FA/error to appear.
  await page.waitForTimeout(15_000);
  console.log(`[2] Post-login URL: ${page.url()}`);
  await context.storageState({ path: STATE_FILE });
  console.log("[2] Session saved to .state/cardladder.json — rerun to test persistence.");
}

console.log(`[3] Searching: ${QUERY}`);
try {
  await page.getByPlaceholder(/search sales history/i).first().fill(QUERY);
  await page.waitForTimeout(6_000); // watch [api] lines for the price/search call
} catch {
  console.log("[3] Search box not found — may not be logged in. Check screenshot.");
}
await page.screenshot({ path: STATE_DIR + "cardladder-search.png", fullPage: true });
console.log("[3] Screenshot: .state/cardladder-search.png — record the AVERAGE price + its API URL.");

console.log("\nGO/NO-GO CHECKLIST — fill in spike/README.md:");
console.log("  [ ] Login scripted OK?           [ ] 2FA type (none/email/sms/totp)?");
console.log("  [ ] Cookie session survives rerun? [ ] Internal JSON API observed (urls above)?");
console.log("  [ ] Price + metric readable?     [ ] Any bot challenge?");
await browser.close();
