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

const browser = await chromium.launch({ headless: false }); // headed: watch for 2FA/captcha
const context = existsSync(STATE_FILE)
  ? await browser.newContext({ storageState: STATE_FILE })
  : await browser.newContext();
const page = await context.newPage();

// Log every JSON response — if the SPA calls an internal API, we want its shape.
page.on("response", async (res) => {
  const ct = res.headers()["content-type"] ?? "";
  if (ct.includes("application/json") && res.url().includes("cardladder")) {
    console.log(`[api] ${res.status()} ${res.url()}`);
  }
});

console.log("[1] Loading cardladder.com ...");
await page.goto("https://www.cardladder.com", { waitUntil: "domcontentloaded" });

const loggedIn = await page
  .locator("text=/sign out|account|portfolio/i")
  .first()
  .isVisible()
  .catch(() => false);

if (!loggedIn) {
  console.log("[2] Logging in (watch the window for 2FA/captcha — note what appears!)");
  await page.getByRole("link", { name: /log ?in|sign ?in/i }).first().click();
  await page.getByLabel(/email/i).fill(EMAIL);
  await page.getByLabel(/password/i).fill(PASSWORD);
  await page.getByRole("button", { name: /log ?in|sign ?in/i }).click();
  // Give a human 60s to complete any 2FA challenge in the headed window.
  await page.waitForTimeout(60_000);
  await context.storageState({ path: STATE_FILE });
  console.log("[2] Session saved to .state/ — rerun to test cookie persistence.");
}

console.log(`[3] Searching: ${QUERY}`);
await page.getByRole("searchbox").or(page.getByPlaceholder(/search/i)).first().fill(QUERY);
await page.keyboard.press("Enter");
await page.waitForTimeout(5_000);
await page.screenshot({ path: STATE_DIR + "cardladder-search.png", fullPage: true });
console.log("[3] Screenshot: .state/cardladder-search.png — record the price + which metric it is.");

console.log("\nGO/NO-GO CHECKLIST — fill in spike/README.md:");
console.log("  [ ] Login scripted OK?           [ ] 2FA type (none/email/sms/totp)?");
console.log("  [ ] Cookie session survives rerun? [ ] Internal JSON API observed (urls above)?");
console.log("  [ ] Price + metric readable?     [ ] Any bot challenge?");
await browser.close();
