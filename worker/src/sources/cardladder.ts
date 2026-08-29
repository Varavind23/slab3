// Card Ladder PriceSource adapter (plan: T4). Metric = CARD LADDER VALUE.
//
// Metric changed 2026-08-29 from average sale (oneMonthData.averagePrice) to Card
// Ladder Value (httpcardestimate.estimatedValue) — the number Card Ladder's own
// app shows. The average silently produced NO price for cards whose 30-day window
// was empty; see the lookupCardValue header in _shared/cardladder.ts and
// spike/README.md 1a.
//
// The real client logic lives in the cross-runtime shared module
// (supabase/functions/_shared/cardladder.ts) — the SAME code the production Supabase
// Edge Function runs. This file adapts it to the worker's PriceSource contract and
// is where the vitest suite exercises the verified Firebase + Cloud Functions
// contract. We NO LONGER touch search.cardladder.com (Cloudflare-walled); the data
// comes from Firebase callables on Google hosts with a Bearer ID token.

import type { CardIdentity, Lookup, PriceSource, SourceError } from "./types.js";
import {
  lookupCardValue,
  type ClErrorKind,
  type FetchLike,
} from "../../../supabase/functions/_shared/cardladder";

// Re-export the pure contract pieces so tests (and any worker caller) share one source.
export {
  signIn,
  refresh,
  isExpired,
  resolveCert,
  estimate,
  lookupCardValue,
  fetchProfileSales,
  parseResolve,
  cardImage,
  parseEstimate,
  parseSales,
  isoOrNull,
  usdToCents,
  AVERAGE_SALE_WINDOW,
  MAX_SALES,
} from "../../../supabase/functions/_shared/cardladder";

const ERROR_MAP: Record<ClErrorKind, SourceError["error"]> = {
  invalid_credentials: "auth_expired",
  auth_expired: "auth_expired",
  rate_limited: "rate_limited",
  not_found: "not_found",
  network: "network",
};

export class CardLadderSource implements PriceSource {
  readonly name = "cardladder" as const;
  readonly metric = "cl_value" as const;

  /** idTokenProvider yields a valid Firebase ID token for the user's OWN Card Ladder
   *  account (the Edge Function supplies one after refresh/sign-in). fetchImpl is
   *  injectable so tests run offline against captured fixtures. */
  constructor(
    private readonly idTokenProvider: () => Promise<string>,
    private readonly fetchImpl?: FetchLike,
  ) {}

  async lookup(identity: CardIdentity): Promise<Lookup> {
    let idToken: string;
    try {
      idToken = await this.idTokenProvider();
    } catch {
      return { kind: "error", error: "auth_expired", detail: "Card Ladder not connected — reconnect your account" };
    }

    const r = await lookupCardValue(idToken, identity.certNumber ?? "", identity.grader, undefined, {
      fetch: this.fetchImpl,
    });
    if (r.kind === "ok") {
      // cert-matched via httpbuildcollectioncard → exact identity.
      return {
        kind: "ok",
        priceCents: r.priceCents,
        metric: this.metric,
        asOf: r.asOf,
        sourceCanonicalId: r.profileId,
        confidence: "exact",
        sourceConfidence: r.estimate.confidence ?? undefined,
        lastSaleCents: r.estimate.lastSalePriceCents ?? undefined,
        lastSaleAt: r.estimate.lastSaleAt ?? undefined,
      };
    }
    if (r.kind === "not_found") return { kind: "error", error: "not_found" };
    return { kind: "error", error: ERROR_MAP[r.error], detail: r.detail };
  }
}
