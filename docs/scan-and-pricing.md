# Scan flow, identity chain, prices

Moved out of CLAUDE.md (2026-10-01) verbatim. Read before touching `CameraSession`, `RecentCertWindow`, `ScanScreen`, `IdentitySource` or `PriceService`.

Scan flow: continuous burst — the camera **never freezes and never blocks**.
`CameraSession` owns an `AVCaptureSession` and runs Vision (`BarcodeDetector`) on
the video frames at 12 Hz, restricted to `ScanGeometry.guideRect`, so **the frame
the barcode was found in IS the photo** (`SlabFrameCapture` crops and encodes it
inline on the video queue). It replaced VisionKit's `DataScannerViewController`,
whose only pixel API — `capturePhoto()` — reconfigured the running session: the
preview froze ~1s AND that await was the sole thing blocking the next slab. There
is no cheaper frame API on that class, which is why we own the session. Two
non-negotiables carried over: `CameraPreview.updateUIView` is **empty on purpose**
(per-update device configuration was a second hitch source), and the pixel buffer
is **never retained past the delegate callback**. Then `CertParser` (grader
auto-detected: psacard/cgccards/cgccomics URL host if it is a URL, else bare digits
10 → CGC, 7–9 → PSA, anything else is not a scan — a GUESS every downstream
consumer must tolerate) → `Card` → `PriceService.refresh`, then
`PsaIdentityService.enrich` (PSA last: it is walled and times out slowly).

`RecentCertWindow` decides which sightings are worth reacting to — it never
prevents a duplicate *row* (`ScanScreen.add` refuses a cert already in the store,
unconditionally). Load-bearing because raw Vision has no item tracking, so a slab
in frame re-detects ~12×/s. **Three** rules: a repeat of the **last admitted cert
is blocked outright, whatever the gap** (that's the camera re-reading what's still
in your hand — and it's what makes glare-intermittent detection safe, where a pure
timer would fire a spurious duplicate); **nothing at all is admitted while the slab
just captured is still in frame**, which re-arms only once it has gone unseen for
`clearance` (0.4s); and any *other* recently-seen cert is held by a short ~1.5s
trailing window. It replaced a session-lifetime `Set`, which erred the other way —
a rescan was swallowed forever and never reached the "already in inventory" check.

That middle rule is the **one-slab-at-a-time hold** (2026-09-15, user report: one
card listed repeatedly in Recent scans). Users work a reversed stack, lifting one
slab at a time, so the slab coming off and the one beneath it share the frame
constantly. It needs the WHOLE frame every pass, which is why
`BarcodeDetector.certificates` returns every cert rather than the first and why
`CameraSession` calls `update(sightings:)` even on passes that detect nothing — an
empty frame is the evidence that the slab left. **Only the admitted cert is
recorded** in a pass that admits one, and only the held slab during a hold: record
the whole frame and the next slab's own trailing window gets pushed back on every
pass, costing about a second of dead air per slab (a test caught that, not a
device). `ScanController.isHolding` drives the viewport copy and dims the guides,
because a deliberate hold and a failed read look identical otherwise.

**The duplicate check must ask the STORE** — `CardLookup.existing`, a
`FetchDescriptor` (pending changes included, so an inserted-but-unsaved card
counts) — never a screen's `@Query`. That array is a rendered value and the scan
callback is handed to the camera once at `onAppear`, so a card inserted moments
ago can be missing from it; at burst cadence that gap is where a second read of one
slab inserted a second row, under a cyan "captured" readout instead of the amber
duplicate one.

**Two scan modes** (2026-09-16), remembered in `@AppStorage("caliper_auto_scan")`
on `ScanScreen` — no other screen reads it, so it is deliberately not in
`AppState`. Auto-scan is everything above. Tap-to-scan runs no Vision at all until
the viewport is tapped (the whole viewport is the shutter, per Caliper §2): a tap
**arms the next detection pass** (`TapCaptureArm`) rather than capturing inline,
because the pixel buffer a tap would want is already recycled by the time the tap
reaches the main actor — the armed pass then encodes the frame the barcode was
really read in, one or two frames later. A tap **bypasses the window's rules** (the
user picked that slab, so a second tap on a card already held must reach the
duplicate readout rather than be swallowed by rule 1) but calls `noteAdmitted`, so
flipping back to auto doesn't re-take the slab still in your hand. A tap that finds
nothing readable expires after 1.2s into the `.noCode` toast — under auto-scan
silence was honest because nothing had been asked, but a tap is a question.

Identity and images resolve through a **ranked chain**, not a single source
(`IdentitySource` + `Card.setIdentity`/`setImage`): PSA → Card Ladder → Courtyard,
with the camera capture as the image floor so a row is never picture-less. It has
to be stored rather than implied by call order, because all three writers are
independent async tasks. A lower source may FILL a gap a better one left, never
overwrite it. Grade rides that same chain and is normalized to a bare number by
`GradeText` at every source (`"10 GEM MINT"` / `"PSA 9"` / `"g9"` → `"10"` / `"9"`),
because it is a `card_key` segment and two spellings would be two keys.
Two rules: **an official image is used only on an exact cert match**
(a fuzzy Courtyard hit is a different card — the image analogue of fabricating a
price), and **the long assembled title never goes in `name`**, which feeds
`refreshCardKey()`; it lives in `Card.title`. Only Card Ladder answers for CGC.
Per-source facts: PSA's cert page carries the assembled title in its `<h1>` (not
in the `<dt>/<dd>` list) and **no card photo at all** unless the cert has
SecureScan; Card Ladder's `resolveCert` returns `label`/`player` plus a public
card render and rides the existing price call — never fetch it separately, that
burns the daily budget; Courtyard's Algolia hits carry a cert-keyed render plus an
`lqipBase64` preview.

Comps (`RecentSale`) follow the same honesty rules as prices: stored per source,
`nil` = never fetched but `[]` = fetched and the source genuinely has none (the
detail screen says something different for each), a failed fetch keeps the last
list, and nothing is ever synthesized to fill the panel.

Prices come from two independent fetches per card (`PriceService.refresh`), so one
source failing never blocks the other. Courtyard is `courtyard-price` (cache-first;
`force: true` comes from exactly two places, the detail screen's "Refresh prices now"
and `ScanScreen.retry`); Card Ladder is only attempted when the user has connected
an account. A refresh **never blanks a value the user already saw**. Only an
authoritative answer clears a price (`PriceWriteback` holds that rule and is tested
directly); a transient failure keeps the last value and marks the column stale.

**There is no bulk refresh** (removed 2026-09-16, owner decision). The Cards tab's
refresh-all button and `PriceRefresher` — which paced a whole folder at 1100 ms for
Card Ladder's ≤1 req/sec rule, or 120 ms on a Courtyard-only run, and dropped Card
Ladder for the rest of a run the moment the connection reported gone — are gone,
because one tap fired a stack-sized burst at exactly the endpoint that 403s an IP for
hammering it, against the per-user Card Ladder budget (200/day then; 400 since 2026-10-19, `_shared/cl-limit.ts`). Prices now arrive on the
scan itself and are re-fetched one card at a time from the detail screen. This
knowingly departs from Caliper §3, which specifies that control and its in-flight
`REFRESHING 9 CARDS · CL, CY` line; the `PRICES REFRESHED …` line stays. Any bulk
path that comes back needs the pacing `PriceRefresher` had — recoverable from git
history — and a scope narrower than "everything visible".

**Pasted cert lists — the one paced bulk path** (owner ask, 2026-10-01). Buyers get a
list of certs from a seller and used to type them one at a time. The Scan header's
pencil (`ManualEntrySheet`) now also takes a pasted list:
- `CertListParser` reads certs out of any text: lines, commas, seller prose, PSA/CGC
  URLs, CGC's grouped `6055 074 171`. Each candidate goes through `CertParser` (the
  camera's grader guess); grades, years, prices and 11+ digit runs are skipped. A
  lone number of odd length is still accepted as PSA — the single-cert sheet always
  took one.
- A live preview shows each cert with a grader chip (tap flips PSA⇄CGC), marks ones
  already in inventory, and lets a row be removed.
- `CertBatch.cap` = 30 NEW certs per add; the overflow stays in the field.
- Every cert goes through `ScanScreen.ingest` — the scan's own duplicate check,
  filing and lot claim — with one summary toast. Prices go through `PricePacer`:
  serial, `PriceRefresher`'s 1100 ms / 120 ms gap after every card. Not persisted —
  an app kill mid-list leaves the rest to per-card refresh.
- Exactly one cert behaves as the sheet always did (`add`, per-card toast).
