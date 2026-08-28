// PSA cert lookup via the PUBLIC cert page (bridge adapter, user decision
// 2026-08-21) — used while official API approval is pending. Same CertData
// output as the official PsaCertLookup, so the pipeline is transport-agnostic;
// swap back to the API the moment access is approved.
//
// Page: https://www.psacard.com/cert/{n}  (200 via browser transport; 403 bare)
// The details render as a <dt>Label</dt><dd>Value</dd> definition list:
//   Cert Number, Item Grade, Label Type, Reverse Cert/Barcode, Year,
//   Brand/Title, Subject, Card Number, Category  (verified against a real cert,
//   2026-08-21; Reverse Cert/Barcode confirmed 2026-08-28).
//
// The <dt>/<dd> list carries only the FRAGMENTS of a card's identity. The
// assembled title PSA itself renders ("2000 POKEMON ROCKET #12 DARK
// SLOWBRO-HOLO") lives in the page <h1> — see parseCertTitle. Resellers
// recognise that string, not the bare Subject, so we parse both.
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

/** The assembled human title from the page heading:
 *  "2000 POKEMON ROCKET #12 DARK SLOWBRO-HOLO".
 *
 *  Two independent sources in the same document, because a layout change to
 *  either one alone shouldn't cost us the title:
 *    1. the <h1> (the real cert page has exactly one), and
 *    2. the Next.js RSC payload's `description`, which sits INSIDE a JS string
 *       literal and is therefore backslash-escaped — a plain `"description":"`
 *       pattern matches nothing here (verified against the fixture 2026-08-28).
 *
 *  `subject` is the Subject label when known; it plus a 4-digit year are the
 *  sanity check that keeps a not-found page's heading from becoming a title. */
export function parseCertTitle(html: string, subject?: string): string | undefined {
  const clean = (s: string) =>
    s.replace(/<[^>]+>/g, "")
      .replace(/&amp;/g, "&")
      .replace(/&#39;|&apos;/g, "'")
      .replace(/&quot;/g, '"')
      .replace(/\s+/g, " ")
      .trim();

  const candidates: string[] = [];
  const h1 = html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i);
  if (h1) candidates.push(clean(h1[1]));
  const rsc = html.match(/\\?"description\\?":\\?"([^"\\]{10,200})\\?"[\s\S]{0,120}?PSA_CERT_WEB/);
  if (rsc) candidates.push(clean(rsc[1]));

  return candidates.find((c) => {
    if (c.length < 6 || c.length > 200) return false;
    if (subject && c.toUpperCase().includes(subject.toUpperCase())) return true;
    return /\b(19|20)\d{2}\b/.test(c);
  });
}

/** First PSA-hosted cert scan, if this cert has SecureScan imagery. Site chrome
 * lives under /psacard/images/, so exclude it (and all marketplace images). */
export function parseCertImageUrl(html: string): string | undefined {
  const decoded = html.replace(/\\u0026/g, "&").replace(/&amp;/g, "&").replace(/\\\//g, "/");
  const urls = decoded.match(/https:\/\/[^"'\s<>]+/gi) ?? [];
  return urls.find((url) => {
    try {
      const parsed = new URL(url);
      return parsed.hostname === "i.psacard.com" && !parsed.pathname.startsWith("/psacard/images/");
    } catch {
      return false;
    }
  });
}

/** The reply the deployed Worker returns and the scrape adapter maps.
 *  `worker/src/index.ts` used to re-implement this assembly inline, which meant
 *  the fixture suite never covered the code Cloudflare actually runs. Both call
 *  here now — that is the point of the three-runtime split (see CLAUDE.md). */
export type CertReply =
  | {
      status: "ok";
      certNumber: string;
      subject?: string;
      set?: string;
      year?: number;
      grade?: string;
      title?: string;
      cardNumber?: string;
      imageUrl?: string;
    }
  | { status: "not_found" }
  | { status: "source_error"; reason: string };

/** PURE: cert page HTML → the reply. Exported so fixtures test the deployed path. */
export function certReplyFromHtml(certNumber: string, html: string): CertReply {
  const labels = parseCertLabels(html);
  if (Object.keys(labels).length === 0) {
    // Empty table = either an unknown cert page or a layout change.
    if (/no results|not found|invalid cert/i.test(html)) return { status: "not_found" };
    return { status: "source_error", reason: "details_not_found" };
  }

  const subject = labels["Subject"] || undefined;
  const year = labels["Year"] ? Number.parseInt(labels["Year"], 10) : undefined;
  return {
    status: "ok",
    certNumber,
    subject,
    set: labels["Brand/Title"] || undefined,
    year: Number.isFinite(year) ? year : undefined,
    grade: parseGrade(labels["Item Grade"]),
    title: parseCertTitle(html, subject),
    cardNumber: labels["Card Number"] || undefined,
    imageUrl: parseCertImageUrl(html),
  };
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

    const reply = certReplyFromHtml(certNumber, html);
    if (reply.status === "not_found") return { kind: "not_found" };
    if (reply.status === "source_error") {
      return { kind: "error", detail: "cert details table not found — PSA page layout changed" };
    }

    const cert: CertData = {
      grader: "psa",
      certNumber,
      name: reply.subject,
      set: reply.set,
      year: reply.year,
      grade: reply.grade,
      title: reply.title,
      cardNumber: reply.cardNumber,
      imageUrl: reply.imageUrl,
      raw: parseCertLabels(html),
    };
    return { kind: "ok", cert };
  }
}
