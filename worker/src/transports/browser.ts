// Production transports backed by a shared Playwright browser context.
//
// One long-lived browser context serves every source that needs to defeat
// Cloudflare TLS fingerprinting (Courtyard JSON, PSA/CGC cert pages, Card
// Ladder). Requests execute INSIDE the page (fetch for JSON, navigation for
// HTML) so they carry a real browser fingerprint. The worker keeps one context
// warm and reuses it; this module is the thin adapter to the two transport
// interfaces the sources consume.

import type { Browser, BrowserContext } from "playwright";
import { chromium } from "playwright";
import type { JsonTransport } from "../sources/transport.js";
import { TransportError } from "../sources/transport.js";
import type { HtmlTransport } from "../sources/html-transport.js";
import { HtmlTransportError } from "../sources/html-transport.js";

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";

/** Owns one browser + context; hands out JSON and HTML transports that ride it.
 *  Call warmUp() once (loads an origin so Cloudflare clears the context), then
 *  reuse for many lookups. Call close() on shutdown. */
export class BrowserPool {
  private browser?: Browser;
  private ctx?: BrowserContext;

  async start(): Promise<void> {
    this.browser = await chromium.launch({ headless: true });
    this.ctx = await this.browser.newContext({ userAgent: UA });
  }

  /** Load an origin so the context passes its bot check before real lookups.
   *  Needed for the JSON transport (Courtyard's api. host must be hit from an
   *  already-cleared context). NOT for the HTML transport — cert-page
   *  navigation clears its own challenge, and warming up first interferes. */
  async warmUp(origin: string): Promise<void> {
    const page = await this.ctx!.newPage();
    await page.goto(origin, { waitUntil: "domcontentloaded", timeout: 30_000 });
    await page.waitForTimeout(4_000);
    await page.close();
  }

  jsonTransport(): JsonTransport {
    const ctx = this.ctx!;
    return {
      async getJson(url: string): Promise<unknown> {
        const page = await ctx.newPage();
        try {
          const res = await page.evaluate(async (u) => {
            const r = await fetch(u, { headers: { Accept: "application/json" } });
            return { status: r.status, text: await r.text() };
          }, url);
          if (res.status >= 400) throw new TransportError(`GET ${url} → ${res.status}`, res.status);
          try {
            return JSON.parse(res.text);
          } catch {
            throw new TransportError(`non-JSON body from ${url}`);
          }
        } finally {
          await page.close();
        }
      },
    };
  }

  /** @param readySelector CSS selector that appears only on the real (post-
   *  Cloudflare-challenge) page. Cloudflare serves a 403 interstitial that
   *  auto-clears in a few seconds, so we ignore the initial nav status and wait
   *  for real content to render instead. */
  htmlTransport(readySelector = "dd"): HtmlTransport {
    const ctx = this.ctx!;
    return {
      async getHtml(url: string): Promise<string> {
        const page = await ctx.newPage();
        try {
          await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
          try {
            // Waits THROUGH the CF challenge until the real details render.
            await page.waitForSelector(readySelector, { timeout: 15_000 });
          } catch {
            // No content selector — either a hard block or a genuine not-found.
            const html = await page.content();
            if (/just a moment|cf-chl|attention required|access denied/i.test(html)) {
              throw new HtmlTransportError(`GET ${url} blocked by challenge`, 403);
            }
            return html; // let the source classify (e.g. not_found)
          }
          return await page.content();
        } finally {
          await page.close();
        }
      },
    };
  }

  async close(): Promise<void> {
    await this.ctx?.close();
    await this.browser?.close();
  }
}
