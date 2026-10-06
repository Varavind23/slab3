// Courtyard price + identity + comps for one scanned slab, from Courtyard's own
// scanner API. One unauthenticated upstream call answers all three.
//
// NO ToS GATE, unlike cardladder-price. Card Ladder data is withheld from users
// without their own subscription — even on a cache hit — because it is a paid
// product. Courtyard's scanner endpoint is public and unauthenticated: there is
// no account to hold, nothing to withhold, and no per-user budget to spend. The
// caller must still be a signed-in Slabs user, so this function is not an open
// proxy for anyone on the internet.
//
// WHY IT IS SERVER-SIDE AT ALL, given there is no secret to protect: a global
// cache. A 200-slab bulk refresh from a phone would otherwise be 200 requests per
// device, re-fetching cards every other user has already fetched. Courtyard 403s
// an IP that hammers it — observed on /index/* during the 2026-08-29 spike — so
// one cached row per cert, shared by everyone, is the difference between polite
// and blocked.
//
// See spike/README.md §2b for the endpoint, and the migration
// 20260831120000_courtyard_scanner_cache.sql for why the cache is one table.

import {
  fetchCardDetails,
  fetchGraderImages,
  attemptsFor,
  CyError,
  type CyScanResult,
  type CyGraderImages,
} from "../_shared/courtyard-scanner.ts";
import { admin, callerId, isSlab, json, logWrite } from "../_shared/http.ts";

/** Same 24h TTL as the Card Ladder price cache. The identity half barely changes,
 *  but it rides the same response, so one expiry for the whole document is both
 *  simpler and honest about what was actually fetched together. */
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const METRIC = "cy_market_value" as const;

interface Body {
  cert: string;
  grader: "psa" | "cgc";
  /** Manual refresh: skip the cache READ so the user gets a current number. */
  force?: boolean;
}

type Row = {
  source_key: string;
  price_cents: number | null;
  source_confidence: number | null;
  grade: string | null;
  title: string | null;
  subject: string | null;
  card_set: string | null;
  card_year: string | null;
  card_number: string | null;
  category: string | null;
  population: number | null;
  image_url: string | null;
  comps: unknown;
  acquisition_accepted: boolean | null;
  fetch_status: string;
  fetched_at: string;
};

/** The identity block the app applies through Card.setIdentity. `grade` is the
 *  load-bearing one: it is a card_key segment, and before this source Card Ladder
 *  was the only supplier of it (PSA's cert page is 403-walled). */
const identityOf = (r: Row) => ({
  grade: r.grade ?? undefined,
  title: r.title ?? undefined,
  subject: r.subject ?? undefined,
  set: r.card_set ?? undefined,
  year: r.card_year ?? undefined,
  cardNumber: r.card_number ?? undefined,
  category: r.category ?? undefined,
  population: r.population ?? undefined,
  imageUrl: r.image_url ?? undefined,
});

const okReply = (r: Row, cached: boolean, stale = false) => ({
  status: "ok",
  priceCents: r.price_cents,
  metric: METRIC,
  asOf: r.fetched_at,
  cached,
  // Served from a cached row because the source is failing right now. The app
  // keeps showing the number rather than blanking it — the PriceWriteback rule.
  stale: stale || undefined,
  confidence: r.source_confidence,
  identity: identityOf(r),
  comps: r.comps ?? [],
  acquisitionAccepted: r.acquisition_accepted ?? undefined,
  sourceKey: r.source_key,
});

const rowOf = (grader: string, cert: string, r: CyScanResult): Row => ({
  source_key: r.sourceKey,
  price_cents: r.priceCents,
  source_confidence: r.confidence ?? null,
  grade: r.identity.grade ?? null,
  title: r.identity.title ?? null,
  subject: r.identity.subject ?? null,
  card_set: r.identity.set ?? null,
  card_year: r.identity.year != null ? String(r.identity.year) : null,
  card_number: r.identity.cardNumber ?? null,
  category: r.identity.category ?? null,
  population: r.identity.population ?? null,
  image_url: r.identity.imageUrls[0] ?? null,
  comps: r.comps,
  acquisition_accepted: r.acquisitionAccepted ?? null,
  fetch_status: "ok",
  fetched_at: new Date().toISOString(),
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ status: "method_not_allowed" }, 405);

  const userId = await callerId(req);
  if (!userId) return json({ status: "unauthorized" }, 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ status: "bad_request" }, 400);
  }
  const { cert, grader, force = false } = body;
  if (!isSlab(cert, grader)) return json({ status: "bad_request" }, 400);

  const db = admin();

  // 1) Cache-first. The key is (grader, cert) — derivable from the scan itself,
  //    so this costs no network and no upstream call for a card anyone has
  //    already looked up.
  const { data: cached } = await db
    .from("cy_scan_cache")
    .select(
      "source_key, price_cents, source_confidence, grade, title, subject, card_set, card_year, card_number, category, population, image_url, comps, acquisition_accepted, fetch_status, fetched_at",
    )
    .eq("grader", grader)
    .eq("cert", cert)
    .maybeSingle<Row>();

  const fresh = cached && Date.now() - new Date(cached.fetched_at).getTime() < CACHE_TTL_MS;
  if (cached && fresh && !force) {
    if (cached.fetch_status === "not_found") {
      // No price, but the row may still hold a slab photograph — pass it on, or a
      // cache hit would silently be worse than a miss.
      return json({
        status: "not_found",
        cached: true,
        identity: { imageUrl: cached.image_url ?? undefined },
      });
    }
    return json(okReply(cached, true));
  }

  // 2) Fetch. One call returns price, identity and comps together.
  let result: CyScanResult;
  try {
    result = await fetchCardDetails(cert, grader);
  } catch (e) {
    const kind = e instanceof CyError ? e.kind : "network";

    // An `unresolvable` 400 NEVER overwrites a price we already hold.
    //
    // 400 and 404 are not equally trustworthy. A 404 is Courtyard's catalog saying
    // it does not know this cert — an answer about the CARD. A 400 is GemRate
    // refusing the QUERY, and we classify it from the status code alone; if their
    // upstream, the WAF, or a deploy ever answers 400 broadly, caching it as
    // not_found would blank good prices across the board for 24h. That is precisely
    // the failure the never-blank rule exists to prevent, so a slab with a stored
    // `ok` row keeps serving it, marked stale, exactly like a 5xx.
    //
    // A 400 is still cached when we hold NOTHING — there is no value to protect,
    // and caching is what stops the request being re-sent on every single refresh
    // forever, which is the bug this whole change set is fixing.
    if (kind === "unresolvable" && cached && cached.fetch_status === "ok") {
      return json(okReply(cached, true, true));
    }

    if (kind === "not_found" || kind === "unresolvable") {
      // AUTHORITATIVE ENOUGH TO CACHE: the catalog does not know the cert (404), or
      // GemRate refused every pairing (400) and we hold no previous answer to keep.
      // Cache it — this is an answer, not a failure — and the app shows an em dash.
      // A card Courtyard cannot PRICE still has a slab photograph, and this is
      // exactly the row that needs one: no price, no marketplace listing, so
      // without this the app falls back to the camera capture. Never throws.
      // Every pairing failed, so the grader we were handed is exactly the thing
      // in doubt — an `unresolvable` means GemRate refused all of them. Walk the
      // same pairings for the picture rather than trusting the guess that just
      // lost. Stops at the first hit; each call is cheap and never throws.
      let imgs: CyGraderImages = {};
      for (const t of attemptsFor(cert, grader)) {
        imgs = await fetchGraderImages(t.cert, t.grader);
        if (imgs.frontUrl ?? imgs.frontThumbUrl) break;
      }
      logWrite("cy_scan_cache", (await db.from("cy_scan_cache").upsert({
        grader,
        cert,
        source_key: `${grader.toUpperCase()}_${cert}`,
        comps: [],
        image_url: imgs.frontUrl ?? imgs.frontThumbUrl ?? null,
        // Written as null, not left out: an upsert only touches the columns it
        // sends, so a previous answer's price and identity used to survive inside
        // a not_found row (review 2026-10-02). Nothing serves them today; nothing
        // should be able to.
        price_cents: null, source_confidence: null, grade: null, title: null, subject: null,
        card_set: null, card_year: null, card_number: null, category: null, population: null,
        acquisition_accepted: null,
        fetch_status: "not_found",
        fetched_at: new Date().toISOString(),
      })).error);
      return json({
        status: "not_found",
        cached: false,
        identity: { imageUrl: imgs.frontUrl ?? imgs.frontThumbUrl ?? undefined },
      });
    }

    // TRANSIENT (5xx — typically their GemRate upstream — or a transport failure).
    // Never cached. If we hold ANY previous answer, serve it rather than nothing:
    // a refresh must not blank a value the user already saw, and on a fresh device
    // the app has no last value of its own to fall back on.
    if (cached && cached.fetch_status === "ok") return json(okReply(cached, true, true));
    return json({ status: "source_error" });
  }

  // 3) Store and answer. A no-model-price card (price 0 / confidence 0 upstream)
  //    is cached as fetch_status 'ok' with price_cents NULL — Courtyard knows the
  //    card, it simply has no number for it, which the UI renders as an em dash.
  const row = rowOf(grader, cert, result);

  // What Courtyard actually answered about, which `fetchCardDetails` may have had
  // to correct: the other grader, or the cert without its leading zeros. The
  // response echoes both, and the parse carries them through.
  const answeredGrader = ((result.identity.grader ?? grader).toLowerCase() === "cgc"
    ? "cgc"
    : "psa") as "psa" | "cgc";
  const answeredCert = result.identity.cert ?? cert;

  // card-details' own `primaryImages` has come back empty on every card sampled, so
  // the photograph comes from the sibling route. Only when we do not already have
  // one: the URL is stable and unsigned, so a stored one never goes bad, and this
  // keeps it to ONE extra upstream call per cert for the life of the row.
  //
  // ASK WITH THE PAIRING THAT ANSWERED, not the one we were asked for. The grader
  // is a guess — nothing in a slab barcode names it, CertParser infers it from
  // digit count — and `fetchCardDetails` corrects a wrong guess by walking
  // `attemptsFor()` past the 400. `card-grader-image` gets no such correction, so
  // sending it the original guess asks about a slab that does not exist and gets
  // 200 with an empty array. Because `fetchGraderImages` never throws, that
  // reached the user as a silently pictureless row on exactly the cards the price
  // fallback had just rescued (2026-09-05).
  if (!row.image_url) {
    const imgs = await fetchGraderImages(answeredCert, answeredGrader);
    row.image_url = imgs.frontUrl ?? imgs.frontThumbUrl ?? null;
  }

  logWrite("cy_scan_cache", (await db.from("cy_scan_cache").upsert({ grader, cert, ...row })).error);
  return json(okReply(row, false));
});
