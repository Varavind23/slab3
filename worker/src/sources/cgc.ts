// CGC cert lookup (plan: T3). Turns a scanned CGC cert number into card data
// (name/set/year/grade) to build card_key. Same CertData output as PSA, so the
// pipeline is source-agnostic.
//
// Access reality (M0 spike, 2026-08-22): CGC has NO official developer API, and
// www.cgccards.com is an AngularJS app behind Cloudflare Turnstile — the cert
// lookup path is interactive-challenge-walled (does NOT auto-clear, unlike PSA).
// So headless scraping is blocked, and cert lookup runs on EVERY scan, which
// makes a human-session bridge awkward (cf_clearance expires mid-session).
//
// Data-source decision is pending (see spike/README.md CGC section). This shell
// implements the CertLookup contract + the Turnstile-block state so the pipeline
// can wire CGC now; parseCgcCertPage() is the seam the chosen source fills:
//   * If we go session-scrape: parse the cert page like psa-scrape.
//   * If third-party API: swap HtmlTransport for a JsonTransport-backed impl.
//   * If the slab QR encodes card data: we may skip lookup entirely for CGC.

import type { CertData, CertLookupResult } from "./psa.js";
import type { HtmlTransport } from "./html-transport.js";
import { HtmlTransportError } from "./html-transport.js";

/** SEAM: parse a CGC cert page's details into label/value pairs. Structure TBD
 *  once we can capture a real (un-challenged) CGC cert page. Empty until then. */
export function parseCgcCertPage(_html: string): Record<string, string> {
  return {};
}

export class CgcCertLookup {
  constructor(private readonly transport: HtmlTransport) {}

  async byCertNumber(certNumber: string): Promise<CertLookupResult> {
    let html: string;
    try {
      html = await this.transport.getHtml(
        `https://www.cgccards.com/certlookup/${encodeURIComponent(certNumber)}/`,
      );
    } catch (e) {
      if (e instanceof HtmlTransportError) {
        if (e.status === 404) return { kind: "not_found" };
        // 403 here is the Cloudflare Turnstile wall — a distinct, expected state.
        if (e.status === 403) return { kind: "error", detail: "CGC blocked by Cloudflare challenge — data source pending" };
        return { kind: "error", detail: e.message };
      }
      return { kind: "error", detail: e instanceof Error ? e.message : "unknown" };
    }

    const labels = parseCgcCertPage(html);
    if (Object.keys(labels).length === 0) {
      return { kind: "error", detail: "CGC cert details not parsed — source/parser not yet wired" };
    }

    const year = labels["Year"] ? parseInt(labels["Year"], 10) : undefined;
    const cert: CertData = {
      grader: "cgc",
      certNumber,
      name: labels["Card"] || labels["Subject"] || undefined,
      set: labels["Set"] || labels["Game"] || undefined,
      year: Number.isFinite(year) ? year : undefined,
      grade: labels["Grade"] || undefined,
      raw: labels,
    };
    return { kind: "ok", cert };
  }
}
