// PSA cert lookup via the PUBLIC cert page (bridge adapter, user decision
// 2026-08-21) — used while official API approval is pending. Same CertData
// output as the official PsaCertLookup, so the pipeline is transport-agnostic;
// swap back to the API the moment access is approved.
//
// Page: https://www.psacard.com/cert/{n}  (200 via browser transport; 403 bare)
// The details render as a <dt>Label</dt><dd>Value</dd> definition list:
//   Cert Number, Item Grade, Label Type, Year, Brand/Title, Subject,
//   Card Number, Category  (verified against a real cert, 2026-08-21).
//
// Parsing note: we extract the label/value pairs with a tolerant regex rather
// than a full DOM parser to keep the worker dependency-light. If PSA changes the
// page structure the pairs come back empty → we report layout_changed, matching
// the CGC scrape's failure contract (an ops alert fires; the app shows pending).

import type { CertData, CertLookupResult } from "./psa.js";
import type { HtmlTransport } from "./html-transport.js";
import { HtmlTransportError } from "./html-transport.js";

/** Pull <dt>Label</dt><dd>Value</dd> pairs out of the cert-details list.
 *  Tolerant of attributes/whitespace; strips tags inside cells. */
export function parseCertLabels(html: string): Record<string, string> {
  const out: Record<string, string> = {};
  const rowRe = /<dt\b[^>]*>([\s\S]*?)<\/dt>\s*<dd\b[^>]*>([\s\S]*?)<\/dd>/gi;
  const strip = (s: string) => s.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
  let m: RegExpExecArray | null;
  while ((m = rowRe.exec(html))) {
    const k = strip(m[1]);
    const v = strip(m[2]);
    if (k) out[k] = v;
  }
  return out;
}

/** Grade label like "EX 5" or "MINT 9" → the numeric grade "5" / "9". */
export function parseGrade(itemGrade: string | undefined): string | undefined {
  if (!itemGrade) return undefined;
  const m = itemGrade.match(/(\d+(?:\.\d+)?)/);
  return m ? m[1] : itemGrade.trim() || undefined;
}

export class PsaScrapeLookup {
  constructor(private readonly transport: HtmlTransport) {}

  async byCertNumber(certNumber: string): Promise<CertLookupResult> {
    let html: string;
    try {
      html = await this.transport.getHtml(`https://www.psacard.com/cert/${encodeURIComponent(certNumber)}`);
    } catch (e) {
      if (e instanceof HtmlTransportError) {
        if (e.status === 404) return { kind: "not_found" };
        if (e.status === 403 || e.status === 429) return { kind: "error", detail: `blocked (${e.status})` };
        return { kind: "error", detail: e.message };
      }
      return { kind: "error", detail: e instanceof Error ? e.message : "unknown" };
    }

    const labels = parseCertLabels(html);
    if (Object.keys(labels).length === 0) {
      // Empty table = either an unknown cert page or a layout change.
      if (/no results|not found|invalid cert/i.test(html)) return { kind: "not_found" };
      return { kind: "error", detail: "cert details table not found — PSA page layout changed" };
    }

    const year = labels["Year"] ? parseInt(labels["Year"], 10) : undefined;
    const cert: CertData = {
      grader: "psa",
      certNumber,
      name: labels["Subject"] || undefined,
      set: labels["Brand/Title"] || undefined,
      year: Number.isFinite(year) ? year : undefined,
      grade: parseGrade(labels["Item Grade"]),
      raw: labels,
    };
    return { kind: "ok", cert };
  }
}
