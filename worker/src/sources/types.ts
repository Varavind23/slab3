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

/** What a source's headline number MEANS. `cl_value` is Card Ladder's own
 *  algorithmic "Value"; `recent_sale` is a real completed sale; `average_sale`
 *  is a trailing-window mean (no longer any source's headline, kept because the
 *  price_cache enum and old rows still carry it). */
export type PriceMetric = "average_sale" | "recent_sale" | "cl_value";

/** One real completed sale, for the comps list on the card detail screen.
 *  Never synthesized — if a source has no sales, the list is empty. */
export interface RecentSale {
  priceCents: number;
  soldAt: string; // ISO 8601
  platform?: string;
  listingType?: string;
  title?: string;
  url?: string;
}

export interface PriceResult {
  kind: "ok";
  priceCents: number;
  metric: PriceMetric;
  asOf: string; // ISO 8601
  sourceCanonicalId?: string; // the source's own id, for card_identity_map
  confidence: "exact" | "probable" | "fuzzy";
  /** The source's OWN 1-5 confidence in the price, distinct from `confidence`
   *  above (which is how sure we are we matched the right card). */
  sourceConfidence?: number;
  /** The single most recent real sale, when the source reports one. */
  lastSaleCents?: number;
  lastSaleAt?: string;
  /** Real recent sales, newest first. Absent = not fetched; empty = fetched and
   *  the source genuinely has none. The two are different facts. */
  recentSales?: RecentSale[];
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
