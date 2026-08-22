// Courtyard price source (plan: T5). Metric = RECENT SALE (buyer decision).
//
// Access model (M0 spike, verified 2026-08-22):
//   * api.courtyard.io is JSON behind Cloudflare TLS fingerprinting — call via a
//     browser-context transport, not bare fetch.
//   * Per-asset endpoint /index/asset/{assetID} returns the full picture:
//       title, attributes (Category/Year/Set), collectible_id,
//       listing_data[] (current ask, USDC), offer_data[] (current bid, USDC),
//       fmv_estimate_usd + fmv_confidence (Courtyard's fair-market estimate).
//   * /index/transactions?tx_type=sale is the global recent-sales feed; filter
//     by assetID for the card's actual recent sale.
//
// Card_key → assetID resolution (resolveAssetId) is the remaining M3 piece: the
// marketplace listing is Next.js server-rendered, so matching a scanned card to
// a vaulted Courtyard asset is the card_identity_map attribute-match work (D10).
// Until that lands, lookup() degrades to not_found — but priceForAsset() works
// today for any known assetID and is fully tested.

import type { CardIdentity, Lookup, PriceSource } from "./types.js";
import { notFound, networkError, layoutChanged } from "./types.js";
import { type JsonTransport, TransportError } from "./transport.js";

const USDC_POLYGON = "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359";

interface CourtyardTx {
  txTime: string;
  assetID: string;
  paymentToken: string;
  paymentAmount: string;
  txType: string;
}
interface CourtyardAmount {
  price?: { amount?: { decimal?: number; usd?: number; raw?: string } };
}
interface CourtyardAsset {
  title?: string;
  collectible_id?: string;
  listing_data?: CourtyardAmount[]; // current ask (side sell)
  offer_data?: CourtyardAmount[]; // current bid (side buy)
  fmv_estimate_usd?: number;
  fmv_confidence?: string;
}

/** USDC 6-decimal integer string → integer cents. "8460000" → 846. */
export function usdcToCents(amount: string): number | null {
  if (!/^\d+$/.test(amount)) return null;
  return Math.round(Number(amount) / 10_000);
}
/** A USD decimal (Courtyard already divides USDC for us) → integer cents. */
export function usdToCents(usd: number | undefined): number | null {
  return typeof usd === "number" && Number.isFinite(usd) ? Math.round(usd * 100) : null;
}

/** Extra Courtyard signals worth surfacing alongside the chosen recent-sale
 *  metric — the buyer negotiates against live asks/bids and Courtyard's fmv. */
export interface CourtyardExtras {
  fmvCents: number | null;
  fmvConfidence?: string;
  askCents: number | null; // lowest current listing
  bidCents: number | null; // highest current offer
}

export class CourtyardSource implements PriceSource {
  readonly name = "courtyard" as const;
  readonly metric = "recent_sale" as const;

  constructor(private readonly transport: JsonTransport) {}

  /** Resolve our card identity to a Courtyard assetID. M3 TODO: attribute match
   *  against the card_identity_map. Returns null until then (D10 degrade). */
  async resolveAssetId(_identity: CardIdentity): Promise<string | null> {
    return null;
  }

  /** Live ask/bid/fmv for an asset — parsed from /index/asset/{id}. */
  async extrasForAsset(assetId: string): Promise<CourtyardExtras | SourceErrorResult> {
    let raw: unknown;
    try {
      raw = await this.transport.getJson(`https://api.courtyard.io/index/asset/${assetId}`);
    } catch (e) {
      return errFromTransport(e);
    }
    if (!raw || typeof raw !== "object") return layoutChanged("empty asset response");
    const a = raw as CourtyardAsset;
    const lowest = (arr?: CourtyardAmount[]) =>
      (arr ?? [])
        .map((x) => usdToCents(x.price?.amount?.usd ?? x.price?.amount?.decimal))
        .filter((n): n is number => n !== null)
        .sort((x, y) => x - y);
    const asks = lowest(a.listing_data);
    const bids = lowest(a.offer_data);
    return {
      fmvCents: usdToCents(a.fmv_estimate_usd),
      fmvConfidence: a.fmv_confidence,
      askCents: asks[0] ?? null,
      bidCents: bids[bids.length - 1] ?? null,
    };
  }

  /** Most recent USDC sale for an assetID from the transactions feed. */
  async recentSaleForAsset(assetId: string): Promise<Lookup> {
    let raw: unknown;
    try {
      raw = await this.transport.getJson(
        `https://api.courtyard.io/index/transactions?offset=0&limit=25&tx_type=sale`,
      );
    } catch (e) {
      const err = errFromTransport(e);
      return { kind: "error", error: err.error, detail: err.detail };
    }
    if (!raw || typeof raw !== "object" || !Array.isArray((raw as { transactions?: unknown }).transactions)) {
      return layoutChanged("transactions[] missing — Courtyard response shape changed");
    }
    const tx = (raw as { transactions: CourtyardTx[] }).transactions
      .filter((t) => t.assetID === assetId && t.txType === "sale")
      .filter((t) => t.paymentToken.toLowerCase() === USDC_POLYGON)
      .sort((a, b) => Date.parse(b.txTime) - Date.parse(a.txTime))[0];
    if (!tx) return notFound(`no recent USDC sale for asset ${assetId}`);
    const cents = usdcToCents(tx.paymentAmount);
    if (cents === null) return layoutChanged(`unparseable paymentAmount "${tx.paymentAmount}"`);
    return { kind: "ok", priceCents: cents, metric: this.metric, asOf: tx.txTime, sourceCanonicalId: assetId, confidence: "exact" };
  }

  async lookup(identity: CardIdentity): Promise<Lookup> {
    const assetId = await this.resolveAssetId(identity);
    if (!assetId) return notFound("card_key not yet resolvable to a Courtyard asset (M3 search endpoint pending)");
    return this.recentSaleForAsset(assetId);
  }
}

// Small shared error mapper (kept local; SourceError shape).
type SourceErrorResult = { kind: "error"; error: import("./types.js").SourceErrorKind; detail?: string };
function errFromTransport(e: unknown): SourceErrorResult {
  if (e instanceof TransportError && e.status && e.status >= 500) return { kind: "error", error: "network", detail: e.message };
  return networkError(e instanceof Error ? e.message : "unknown");
}
