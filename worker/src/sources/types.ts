// The single contract every price source implements (plan: T3).
// One shape so the worker treats Card Ladder, Courtyard, PSA, CGC uniformly and
// a dead source degrades predictably instead of crashing the pipeline (D10).

/** Normalized card identity — the `card_key` plus the raw slab metadata a
 *  source may need to find its own catalog entry. */
export interface CardIdentity {
  cardKey: string; // grader:set:card_id:grade  (mirrors make_card_key in SQL)
  grader: "psa" | "cgc";
  name?: string;
  set?: string;
  year?: number;
  grade?: string;
  certNumber?: string;
}

export type PriceMetric = "average_sale" | "recent_sale";

export interface PriceResult {
  kind: "ok";
  priceCents: number;
  metric: PriceMetric;
  asOf: string; // ISO 8601
  sourceCanonicalId?: string; // the source's own id, for card_identity_map
  confidence: "exact" | "probable" | "fuzzy";
}

export type SourceErrorKind =
  | "not_found"
  | "layout_changed"
  | "auth_expired"
  | "rate_limited"
  | "account_locked"
  | "network";

export interface SourceError {
  kind: "error";
  error: SourceErrorKind;
  detail?: string;
}

export type Lookup = PriceResult | SourceError;

export interface PriceSource {
  readonly name: "cardladder" | "courtyard";
  readonly metric: PriceMetric;
  lookup(identity: CardIdentity): Promise<Lookup>;
}

export const notFound = (detail?: string): SourceError => ({ kind: "error", error: "not_found", detail });
export const layoutChanged = (detail?: string): SourceError => ({ kind: "error", error: "layout_changed", detail });
export const networkError = (detail?: string): SourceError => ({ kind: "error", error: "network", detail });
