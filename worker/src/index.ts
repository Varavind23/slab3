import puppeteer from "@cloudflare/puppeteer";
import { certReplyFromHtml } from "./sources/psa-scrape.js";

interface Env {
  BROWSER: Fetcher;
  PSA_SCRAPER_TOKEN: string;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

async function sameSecret(candidate: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(candidate)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const a = new Uint8Array(left);
  const b = new Uint8Array(right);
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a[index] ^ b[index];
  return difference === 0;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/lookup") return json({ status: "not_found" }, 404);

    const bearer = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!env.PSA_SCRAPER_TOKEN || !(await sameSecret(bearer, env.PSA_SCRAPER_TOKEN))) {
      return json({ status: "unauthorized" }, 401);
    }

    let certNumber = "";
    try {
      const body = await request.json() as { certNumber?: unknown };
      certNumber = String(body.certNumber ?? "").trim();
    } catch {
      return json({ status: "bad_request" }, 400);
    }
    if (!/^\d{7,10}$/.test(certNumber)) return json({ status: "bad_request" }, 400);

    const browser = await puppeteer.launch(env.BROWSER);
    try {
      const page = await browser.newPage();
      const response = await page.goto(`https://www.psacard.com/cert/${encodeURIComponent(certNumber)}`, {
        // PSA keeps analytics/consent requests alive indefinitely. Waiting for
        // networkidle0 turns healthy pages into timeouts; the definition list is
        // the readiness signal we actually care about.
        waitUntil: "domcontentloaded",
        timeout: 30_000,
      });
      if (response?.status() === 404) return json({ status: "not_found" });
      if (!response) return json({ status: "source_error", reason: "no_navigation_response" }, 502);
      if (response.status() >= 400) {
        console.error("PSA navigation rejected", { certNumber, status: response.status() });
        return json({ status: "source_error", reason: `http_${response.status()}` }, 502);
      }

      try {
        await page.waitForSelector("dt", { timeout: 15_000 });
      } catch {
        // Some PSA responses contain the not-found copy without a details list;
        // page.content below distinguishes that from a layout/blocking failure.
      }

      const html = await page.content();
      const reply = certReplyFromHtml(certNumber, html);
      if (reply.status === "source_error") return json(reply, 502);
      return json(reply);
    } catch (error) {
      console.error("PSA lookup failed", {
        certNumber,
        message: error instanceof Error ? error.message : String(error),
      });
      return json({ status: "source_error", reason: "browser_failure" }, 502);
    } finally {
      await browser.close();
    }
  },
} satisfies ExportedHandler<Env>;
