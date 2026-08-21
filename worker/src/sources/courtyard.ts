// Courtyard price source (plan: T5). Metric = RECENT SALE (buyer decision).
//
// Access model (M0 spike, verified 2026-08-21):
//   * api.courtyard.io is JSON, but behind Cloudflare TLS fingerprinting — must
//     be called through a browser-context transport, not bare fetch.
//   * Sale prices come as USDC on Polygon: paymentToken 0x3c49...c3359, and
//     paymentAmount is a 6-decimal integer string ("8460000" = $8.46).
//
// Open piece (tracked for M3): the card_key → Courtyard assetID resolution
// endpoint. The transactions feed proves price access; per-card search is wired
// through `resolveAssetId` and returns not_found until the search endpoint is
// confirmed by watching a real card search. Everything else is done + tested.

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
interface TxResponse {
  transactions: CourtyardTx[];
}

/** USDC 6-decimal integer string → integer cents. "8460000" → 846. */
export function usdcToCents(amount: string): number | null {
  if (!/^\d+$/.test(amount)) return null;
  // 6 decimals of USDC; cents = amount / 1e6 * 100 = amount / 1e4, rounded.
  return Math.round(Number(amount) / 10_000);
}

export class CourtyardSource implements PriceSource {
  readonly name = "courtyard" as const;
  readonly metric = "recent_sale" as const;

  constructor(private readonly transport: JsonTransport) {}

  /** Resolve our card identity to Courtyard's assetID. M3 TODO: confirmed search
   *  endpoint. Returns null until then (adapter degrades to not_found, D10). */
  async resolveAssetId(_identity: CardIdentity): Promise<string | null> {
    return null;
  }

  /** Most recent USDC sale for a given assetID from the transactions feed. */
  async recentSaleForAsset(assetId: string): Promise<Lookup> {
    let raw: unknown;
    try {
      raw = await this.transport.getJson(
        `https://api.courtyard.io/index/transactions?offset=0&limit=25&tx_type=sale`,
      );
    } catch (e) {
      if (e instanceof TransportError && e.status && e.status >= 500) return networkError(e.message);
      return networkError(e instanceof Error ? e.message : "unknown");
    }

    if (!raw || typeof raw !== "object" || !Array.isArray((raw as TxResponse).transactions)) {
      return layoutChanged("transactions[] missing — Courtyard response shape changed");
    }

    const tx = (raw as TxResponse).transactions
      .filter((t) => t.assetID === assetId && t.txType === "sale")
      .filter((t) => t.paymentToken.toLowerCase() === USDC_POLYGON)
      .sort((a, b) => Date.parse(b.txTime) - Date.parse(a.txTime))[0];

    if (!tx) return notFound(`no recent USDC sale for asset ${assetId}`);

    const cents = usdcToCents(tx.paymentAmount);
    if (cents === null) return layoutChanged(`unparseable paymentAmount "${tx.paymentAmount}"`);

    return {
      kind: "ok",
      priceCents: cents,
      metric: this.metric,
      asOf: tx.txTime,
      sourceCanonicalId: assetId,
      confidence: "exact",
    };
  }

  async lookup(identity: CardIdentity): Promise<Lookup> {
    const assetId = await this.resolveAssetId(identity);
    if (!assetId) return notFound("card_key not yet resolvable to a Courtyard asset (M3 search endpoint pending)");
    return this.recentSaleForAsset(assetId);
  }
}
