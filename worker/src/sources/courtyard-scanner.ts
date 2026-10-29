// Courtyard SCANNER adapter — the source that actually answers for a scanned slab.
//
// The client logic lives in the cross-runtime shared module
// (supabase/functions/_shared/courtyard-scanner.ts) — the SAME code the production
// Edge Function runs — exactly like cardladder.ts. This file adapts it to the
// worker's contracts and is where vitest exercises it against fixtures captured
// from real calls. Logic changes go in _shared/, never here.
//
// Relationship to the other two Courtyard adapters (all three are live, none is
// dead code):
//   courtyard-scanner.ts  cert -> price + identity + comps. THE price source for a
//                         scanned slab. Cert-keyed, so exact by construction.
//   courtyard-algolia.ts  marketplace search: the live ASK and the cert-keyed
//                         render image. No longer a price source (2026-08-31).
//   courtyard.ts          per-vaulted-asset detail (ask/bid/FMV), browser transport.
//
// See spike/README.md §2b for the teardown that found the endpoint and the
// on-device confirmation that its numbers are the ones Courtyard's app displays.

import type { RecentSale } from "./types.js";
import {
  fetchCardDetails,
  type CyErrorKind,
  type CyScanResult,
  type CySaleGroup,
} from "../../../supabase/functions/_shared/courtyard-scanner";

export {
  fetchCardDetails,
  parseCardDetails,
  cySourceKey,
  SCANNER_UA,
  SCANNER_ACQ_HEADER,
  attemptsFor,
  fetchGraderImages,
  parseGraderImages,
  gradeLabel,
  cyConfidence,
  usdToCents,
  CyError,
} from "../../../supabase/functions/_shared/courtyard-scanner";
export type { CyScanResult, CyIdentity, CySaleGroup, CyGrader, CyGraderImages } from "../../../supabase/functions/_shared/courtyard-scanner";

/** The metric name this source writes to price_cache. Courtyard's own label for
 *  the number is "Market Value" (scanner.courtyardPricing.marketValue in their
 *  app), and it is a MODEL estimate, not a sale — distinct from `recent_sale`. */
export const CY_METRIC = "cy_market_value" as const;

/** Comps for the slab's OWN grade, newest first — what the detail screen shows.
 *
 *  Matched on grader AND grade because a card's history spans graders: cert
 *  96679812 returns two grade-10 groups, PSA (pop 23) and SGC (pop 3). Returning
 *  [] is a real answer ("Courtyard knows this card and it has no sales at this
 *  grade"), distinct from never having fetched — the same distinction prices draw.
 *  A slab whose own grade has no group gets [], never another grade's sales. */
export function salesForGrade(result: CyScanResult, grader?: string, grade?: string): RecentSale[] {
  const wantGrader = (grader ?? result.identity.grader ?? "").toUpperCase();
  const wantGrade = grade ?? result.identity.grade;
  if (!wantGrade) return [];
  const group = result.comps.find(
    (g: CySaleGroup) => (g.grader ?? "").toUpperCase() === wantGrader && g.grade === wantGrade,
  );
  return (group?.sales ?? []).map((s) => ({ priceCents: s.priceCents, soldAt: s.soldAt }));
}

/** The population Courtyard reports for the slab's own card+grade, for the comps
 *  panel header. Falls back to graderData.population, which is the card's total. */
export function populationForGrade(result: CyScanResult, grader?: string, grade?: string): number | undefined {
  const wantGrader = (grader ?? result.identity.grader ?? "").toUpperCase();
  const wantGrade = grade ?? result.identity.grade;
  const group = result.comps.find(
    (g: CySaleGroup) => (g.grader ?? "").toUpperCase() === wantGrader && g.grade === wantGrade,
  );
  return group?.population ?? result.identity.population;
}

/** CyError kinds → the statuses the Edge Function returns and the app degrades on.
 *  `source_error` must never blank a price the user already saw. */
export const CY_ERROR_STATUS: Record<CyErrorKind, "not_found" | "source_error"> = {
  not_found: "not_found",
  // Every (cert, grader) pairing was refused by GemRate. Deterministic, so it is
  // an ANSWER (no Courtyard value for this slab) and gets cached like a 404 —
  // classifying it as transient is what made these cards retry forever in silence.
  unresolvable: "not_found",
  source_error: "source_error",
  network: "source_error",
  // A refused credential is never an answer about the card: never cached.
  auth_expired: "source_error",
};

export type { CyErrorKind };
export { fetchCardDetails as fetchScannerCardDetails };
