// PSA cert lookup (plan: T3). NOT a price source — this turns a scanned PSA
// cert number into card data (name/set/year/grade) so we can build card_key.
//
// API (per PSA Public API docs, api.psacard.com/publicapi):
//   GET /cert/GetByCertNumber/{certNumber}
//   Header: Authorization: bearer <token>
//   Success: { ...cert fields..., IsValidRequest: true, ServerMessage: "Request successful" }
//   Bad format: { IsValidRequest: false, ServerMessage: "Invalid CertNo" }
//   No data:    { IsValidRequest: true,  ServerMessage: "No data found" }
//   403 "approved customers" = account not approved for API access.
//   429 = daily quota exceeded.
//
// STATUS 2026-08-21: token generated but account is NOT yet approved (403) /
// quota-limited (429). Fixtures below follow the DOCUMENTED contract; replace
// test/fixtures/psa-*.json with a live capture once PSA approves access.

import type { JsonTransport } from "./transport.js";
import { TransportError } from "./transport.js";

export interface CertData {
  grader: "psa" | "cgc";
  certNumber: string;
  name?: string; // Subject
  set?: string; // Brand
  year?: number;
  grade?: string; // CardGrade / GradeDescription
  raw: unknown;
}

export type CertLookupResult =
  | { kind: "ok"; cert: CertData }
  | { kind: "invalid"; message: string } // bad cert-number format
  | { kind: "not_found" } // valid format, no data
  | { kind: "not_approved" } // 403 — account needs PSA approval
  | { kind: "quota" } // 429 — daily quota exceeded
  | { kind: "error"; detail: string };

interface PsaEnvelope {
  IsValidRequest?: boolean;
  ServerMessage?: string;
  // Cert fields may be nested under PSACert or inlined at top level depending on
  // the response version; we read both.
  PSACert?: Record<string, unknown>;
  [k: string]: unknown;
}

function num(v: unknown): number | undefined {
  const n = typeof v === "string" ? parseInt(v, 10) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? n : undefined;
}
function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length ? v : undefined;
}

export class PsaCertLookup {
  constructor(private readonly transport: JsonTransport) {}

  async byCertNumber(certNumber: string): Promise<CertLookupResult> {
    let raw: unknown;
    try {
      raw = await this.transport.getJson(
        `https://api.psacard.com/publicapi/cert/GetByCertNumber/${encodeURIComponent(certNumber)}`,
      );
    } catch (e) {
      if (e instanceof TransportError) {
        if (e.status === 403) return { kind: "not_approved" };
        if (e.status === 429) return { kind: "quota" };
        return { kind: "error", detail: e.message };
      }
      return { kind: "error", detail: e instanceof Error ? e.message : "unknown" };
    }

    const env = (raw ?? {}) as PsaEnvelope;
    if (env.IsValidRequest === false) {
      return { kind: "invalid", message: env.ServerMessage ?? "Invalid request" };
    }
    if (env.ServerMessage && /no data found/i.test(env.ServerMessage)) {
      return { kind: "not_found" };
    }

    const c = (env.PSACert ?? env) as Record<string, unknown>;
    return {
      kind: "ok",
      cert: {
        grader: "psa",
        certNumber,
        name: str(c.Subject),
        set: str(c.Brand),
        year: num(c.Year),
        grade: str(c.CardGrade) ?? str(c.GradeDescription),
        raw,
      },
    };
  }
}
