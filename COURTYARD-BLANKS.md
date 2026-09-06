# Courtyard blanks: cards with no price, no photo, no confidence

**Status: ROOT CAUSE FOUND 2026-09-06 — see §8. Fix not yet applied.**
Every `/scanner/*` request must carry `cy-supports-acquisition-status: 1`. Without
it a large class of certs 404s and reads to us as "Courtyard has no data". Opened
2026-09-05.

Read `spike/README.md` §2b and §2e first for what the endpoints are and how they
fail — this document is only about *our* handling of them, not about access.

---

## 1. The symptom, as reported

On **Slabs Dev 0.4 (build 4)**, side-loaded 2026-09-05, *some* cards show all
three of:

- no price (em dash),
- no slab photograph,
- no / wrong Courtyard confidence meter.

"Some" is unquantified. The failing certs have **not** been identified, and that
is the single biggest gap in this investigation — see §6.

The three symptoms arriving *together* is the important clue. They are three
different fields from **one** upstream call, so the natural reading is one
failure of the whole `courtyard-price` path for those certs, not three
independent bugs. That reading turned out to be only half right.

---

## 2. Confirmed bug: the slab photo was fetched with the *guessed* grader

**This is a real bug, it was introduced by the 2026-09-05 grader-image change
set (`017b853`), and it is now fixed and deployed.**

### Root cause

Nothing in a slab barcode names the grader. `CertParser` infers it from digit
count (`ios/Slab3/Scanning/CertParser.swift`): 10 digits → CGC, 7–9 → PSA. That
inference is a **guess**, and the pipeline is built to survive a wrong one:
`fetchCardDetails` walks `attemptsFor()` — caller's guess, then the other grader,
then zero-stripped variants — but **only past a 400**, because GemRate answers a
wrong `(cert, grader)` pairing with `400 InvalidArgument` rather than a 404.

So the **price** recovers from a wrong guess. The **image** did not.
`supabase/functions/courtyard-price/index.ts` called:

```ts
const imgs = await fetchGraderImages(cert, grader);   // ← the REQUEST's grader
```

`card-grader-image` gets no `attemptsFor()` correction of its own. Handed the
original wrong guess, it asks about a slab that does not exist and returns
**200 with an empty `primaryImages`**. And because `fetchGraderImages`
deliberately **never throws** (by design — a missing picture must never reach the
`source_error` path and blank a price), the failure was structurally silent.

Net effect: **on exactly the cards the price fallback had just rescued, the photo
was silently dropped.**

### Live reproduction (2026-09-05, cert `4260611176`, a CGC slab)

| Asked as | `card-details` | `card-grader-image` |
|---|---|---|
| `PSA` (a wrong guess) | **400** → `attemptsFor()` rescues the price | **0 images** |
| `CGC` (the truth) | 200 | **4 images** |

### The fix (deployed, script size 119.2 kB)

Two paths in `courtyard-price/index.ts`:

1. **The `ok` path** now asks with the pairing that actually *answered*, derived
   from the echoed `identity.grader` / `identity.cert` rather than the request:
   ```ts
   const imgs = await fetchGraderImages(answeredCert, answeredGrader);
   ```
2. **The all-400 (`unresolvable`) path** now walks `attemptsFor()` for the
   picture too, stopping at the first hit. There the grader is *definitionally*
   the thing in doubt — an `unresolvable` means GemRate refused every pairing —
   so trusting the guess that just lost is exactly wrong.

**This fix is server-side. It reaches the phone with no new build.**

### What the fix does NOT do

Rows already cached with a null `image_url` keep serving that row for the **24h
TTL**. A card that was wrong before the fix stays wrong until either the TTL
expires or the user forces a refresh from the detail screen
(`CardDetailScreen.swift:47` → `PriceService.refresh(force: true)`), which is the
only `force` path in the app.

---

## 3. What is still NOT explained: the missing price and confidence

**A wrong grader guess still produces a correct price.** The 400 fallback works —
that is the whole point of `attemptsFor()`, and it is verified live. So the photo
bug in §2 does **not** account for a card showing an em dash and no confidence.

There is at least one more thing going on, or the observation includes cards that
are behaving correctly. Two candidate explanations, and they are
distinguishable in about a minute *given a cert number*:

### Hypothesis A — those certs are genuinely unknown to GemRate (NOT a bug)

If **every** pairing in `attemptsFor()` returns 400, that is the `unresolvable`
kind: authoritative, cached like a 404, rendered as an em dash with no
confidence. That is **correct, designed behaviour** — the no-fabricated-price
rule. A card Courtyard's own app cannot price should look exactly like this.

This hypothesis predicts all three symptoms at once, which fits the report
suspiciously well.

**How to test:** hit the upstream directly, no auth needed:

```sh
UA="Slabs/1.0 (graded-card inventory)"
curl -s -w '\n[%{http_code}]\n' -H "User-Agent: $UA" \
  "https://api.courtyard.io/scanner/card-details?cert=<CERT>&grader=PSA"
# repeat with grader=CGC, and with leading zeros stripped
```

All-400 across both graders ⇒ Hypothesis A, not a bug. A 200 under *either*
grader ⇒ a real bug in our path, escalate.

### Hypothesis B — something else in the deployed function is failing

**The Edge Function has never been verified end to end.** See §4.1. This change
set added the `image_url` writes and the whole `unresolvable` branch to
`index.ts`, and none of it is covered by any test suite. A throw anywhere in
there lands on `source_error`, which the app renders as… no price, no
confidence, no photo. Indistinguishable from Hypothesis A at the UI.

**How to test:** the three curls in `supabase/functions/README.md` §"Local smoke
test", against the deployed function with a real JWT. Blocked today — see §4.2.

#### Findings — 2026-09-05 (evening), from the live database and upstream

The QA-account block turned out not to matter: the deployed function can be
verified from what it *wrote*. `supabase db query --linked` reaches
`cy_scan_cache` through the management API with no DB password, and the deployed
bundle can be pulled with `supabase functions download courtyard-price`.

**B is effectively ruled out for the reported cards.**

1. **The deployed code is the local code.** Version 4 of `courtyard-price`
   (deployed 2026-09-05 22:39 UTC) was downloaded and diffed against
   `supabase/functions/courtyard-price/index.ts`: the differences are formatting
   only (the bundler strips types and reflows). `attemptsFor`, `answeredGrader`
   and both image paths are in the live bundle.

2. **The failing certs ARE identified — §6 item 1 is resolved.** The table holds
   exactly one scan burst for the SlabsDev build: 14 rows written between
   2026-09-05 20:29:34 and 20:30:43 UTC (13:29 PDT). The rows also prove the
   118.4 kB (version 3) deploy was live at that moment, since `image_url` is
   populated on some of them and version 2 never wrote it.

   | rows | `fetch_status` | `image_url` | what the row renders as |
   |---|---|---|---|
   | 6 | `not_found` | null | **em dash, no confidence, camera photo — the report** |
   | 2 | `not_found` | set | em dash, no confidence, Courtyard photo |
   | 4 | `ok` | null | price + meter, camera photo |
   | 2 | `ok` | set | everything |

   The six all-three-symptom certs: **60478273, 62320645, 60928769, 60928772,
   60928787, 66581638.** Three of them (60928769/72/87) are one PSA submission,
   so they are real PSA slabs, not a mis-read grader.

3. **Every row matches a live probe of the upstream, today.** All six 404 on
   `card-details` as PSA, and 400 as SGC, BGS and CGC — so the grader guess was
   right and there is no pairing left to try. All six return
   `200 {"primaryImages": null, "status": "NO_IMAGE"}` from `card-grader-image`.
   The function stored exactly what Courtyard said. Nothing threw, nothing landed
   on `source_error`, and the `.unavailable` path on the phone is not needed to
   explain any observed row. (Transient failures write no row, so the table
   cannot strictly exclude one — see §6 for the log check that would.)

4. **The §2 fix touched none of these cards.** Across all 40 rows in the table,
   **zero** have a `source_key` that disagrees with the requested grader:
   `fetchCardDetails` never had to correct a guess in production. The fix is
   correct and worth keeping, but it explains no symptom anyone saw.

5. **"9 of 9" image coverage does not generalise.** Four of the six *priced*
   cards in the burst (47849607, 57538209, 61113679, 61226379) are `NO_IMAGE`
   upstream. The nine measured earlier were a biased sample of certs already in
   Courtyard's store. So "priced but camera photo" is the upstream having no
   picture, not a bug in our path. Note also that `index.ts` only asks for an
   image on a network miss — an `ok` row with a null `image_url` is served for
   the whole TTL with no retry, so a slab Courtyard photographs later never gets
   its picture until the row expires.

**What this leaves.** The six cards are the 404 class. The document's Hypothesis
A calls that "correct, designed behaviour — a card Courtyard's own app cannot
price". That framing is unverified for these six and is *disproved* for two
others: `spike/README.md` §2e shows certs 129123650 and 110578584 priced in
Courtyard's own app ($36.90 / $172.30) while our GET 404s — still 404 today.
A 404 is authoritative about **our anonymous GET**, not about Courtyard's data.
The "account theory is retired" paragraph in §2e only shows anonymous access
works for certs already in their store; the fresh-bearer replay of a 404 cert
was never run with a valid token.

**The discriminating test, in order:**
1. Owner scans **60928769** and **66581638** in Courtyard's app. Blank there ⇒
   no bug, the em dash is right. Priced there ⇒ the 404 class is the real
   defect and nothing in our pipeline fixes it.
2. Re-GET `card-details?cert=60928769&grader=PSA` 60 s and 10 min after that
   scan. A 200 means their scan lazily populates the store we read.
3. Fresh Privy bearer (`npm run courtyard:auth`, then `CY_CODE=…`) replaying
   129123650. A 200 confirms auth is the unlock; a 404 leaves "a different
   call", which only a Hermes string dump of `scanner/` routes or an HTTPS
   capture of their app can settle.
4. Supabase dashboard → Edge Function logs → `courtyard-price`, 20:29–20:31 UTC:
   exactly 14 invocations, all 200, closes the `.unavailable` gap in point 3.

**Queries used** (rerunnable):
```sh
supabase db query --linked "select cert, fetch_status, image_url is null as no_image, fetched_at
  from cy_scan_cache where fetched_at > '2026-09-05 20:00' order by fetched_at"
supabase db query --linked "select count(*) from cy_scan_cache
  where upper(grader::text)||'_'||cert <> source_key"     -- 0 = no grader ever corrected
supabase functions download courtyard-price --project-ref rrkvlrtohmylhslpzuvz
```

---

## 4. Secondary issues found along the way

These are real, they are separate from the bug above, and most of them are the
reason the bug above was invisible.

### 4.1 `index.ts` has zero test coverage — this is the structural gap

`CLAUDE.md` says "Edge Function logic is covered offline by the `worker/` vitest
suite". That is true of **`_shared/`** and false of the function bodies.
`worker/` cannot import `index.ts`: it pulls in `_shared/http.ts`, which is
Deno-only (reads `Deno.env` at module load, imports supabase-js from esm.sh).

So the 129 vitest tests are green and always were — they never touched the file
with the bug in it. The bug lived in the ~40 lines of glue that decide *what to
ask for*, which is precisely where a guess-correction bug can hide. **Any fix
here that does not add coverage of that glue leaves the next one just as
invisible.** Options: extract the pairing/answer logic into `_shared/` where
vitest can reach it, or stand up a Deno test suite for the functions.

### 4.2 The QA test account cannot sign in

`SLABS_EMAIL` / `SLABS_PASSWORD` in `spike/.env` are rejected by Supabase auth:

```
400 {"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}
```

The credentials parse correctly and the anon key resolves, so this is the account
itself, not the harness. `supabase/EMAIL.md` is new and untracked in this tree,
and notes nothing sends until a confirmation or reset flow is turned on — the
likely cause is an unconfirmed account, **unverified**. Consequence: the README
smoke tests cannot run, so every Edge Function deploy today is going out
unverified against the real thing. This is worth fixing before it hides the next
bug too.

### 4.3 The cache is keyed on the guess, and can disagree with itself

`rowOf()` writes `source_key: r.sourceKey` — the pairing that **answered** — but
the row's key columns `(grader, cert)` are the ones **requested**:

```ts
await db.from("cy_scan_cache").upsert({ grader, cert, ...row });
```

Two consequences:

- One physical slab can occupy **two rows** — one per grader it was scanned as —
  and the stored `grader` column can contradict `source_key` in the same row.
- Lookups are keyed on the guess, so they are *consistent* (the next scan sends
  the same guess and hits the same row), which is why this has not caused a
  visible failure. It is still a latent trap for anything that reads the table
  by grader, including any future backfill or dedupe.

Not fixed. Deliberately out of scope of today's change, but it should be a
decision rather than an accident.

### 4.4 Image failures are invisible by construction

`fetchGraderImages` never throws, and never logs. That is the right call for the
price path — the whole point is that a missing picture cannot blank a number —
but it means there is **no signal anywhere** when the image lookup comes back
empty. The §2 bug ran in production and produced no error, no metric, no log
line. Some counter distinguishing "empty because the cert has no photo" from
"empty because we asked wrong" would have caught this on day one.

### 4.5 The failure path now costs more upstream calls

Post-fix, an `unresolvable` cert can issue up to **4** `card-details` calls
(`attemptsFor`) **plus** up to **4** `card-grader-image` calls. Courtyard 403s an
IP that hammers it — that is the documented reason the app goes through a shared
Edge Function at all. The result is cached, so this is once per cert per 24h, not
per refresh. Probably fine; worth watching if bulk scans of unknown certs become
common. If it bites, stop the image walk at the first *200-with-empty* rather
than trying all four.

### 4.6 `CertParser`'s digit heuristic is the root input to all of this

`10 → CGC`, `7–9 → PSA`, anything else → no scan at all. Every wrong grader guess
downstream starts here. CGC certs that are not 10 digits, or PSA certs that are,
will misguess — and the system is *designed* to absorb that via `attemptsFor()`,
which is correct. But it means "the guess is wrong" is a normal, expected state,
not an edge case, and **every** consumer of the requested grader must be audited
for the §2 mistake. The image call was one. §4.3 is arguably another.

### 4.7 Minor: CGC grade labels collapse

Courtyard returns CGC grades like `g10pristine` (verified live on cert
`4260611176`). `GradeText.normalized` correctly yields `"10"`, so `card_key` is
consistent and this is **not** a bug. But CGC Pristine 10 and Gem Mint 10 are
different grades in CGC's world and both become `"10"`. Comps are grouped by
`(grader, grade)` upstream with the same collapse, so we agree with the source.
Noted only so nobody rediscovers it and assumes it is broken.

---

## 5. What was verified working (so nobody re-litigates it)

All live against `api.courtyard.io` on 2026-09-05, not fixtures:

| Check | Result |
|---|---|
| cert `96679812` PSA | $50.80, confidence 2 — the acceptance bar |
| cert `4260611176` CGC | $111, confidence 5 |
| `card-grader-image` on `96679812` | front + back; full-size entries carry **no `imageSize` key** |
| unknown cert `99999999` | 200 with an **empty** array |
| `96679812` asked as CGC | **400** `InvalidArgument` |
| absent User-Agent | **403** |

Also verified by reading, not assumed:

- The Swift client does **not** drop the image on the no-price path.
  `CourtyardScannerClient` returns `.noPrice(reply.identity, comps)` for
  `not_found`, and `PriceService` passes `identity?.imageUrl` into
  `fillCourtyardImage` on the `.notListed` branch. That chain is intact.
- `worker/` vitest: 129/129 across 8 files. iOS: 80/80 in 12 suites.

---

## 6. What is needed next, in order

1. **Cert numbers for 2–3 failing cards.** Everything in §3 is one curl away once
   those exist, and nothing else can proceed without them. This is the blocker.
2. **A working QA account** (§4.2), so the deployed function can be smoke-tested
   at all.
3. **Coverage of the function glue** (§4.1), or the next bug of this shape is
   equally invisible.
4. Decide on §4.3 (cache keyed on the guess) deliberately.

---

## 7. Timeline

| When | What |
|---|---|
| 2026-09-05 | `017b853` — grader-image source, authoritative 400, UA wall, 3-segment CY meter. 129 + 80 tests green. |
| 2026-09-05 | `courtyard-price` deployed (118.4 kB). **Smoke test skipped** — §4.2. |
| 2026-09-05 | `98c3cd8` — bump to 0.4 (build 4). Archive → export → `altool` upload, delivery `2ee1fc71-0ba4-4561-92f9-1196d84a67d5`. Both commits pushed to `origin/main`. |
| 2026-09-05 | SlabsDev 0.4 (4) side-loaded to varun's iphone (`com.varunaravind.slabs.dev`, coexists with TestFlight). |
| 2026-09-05 | Symptoms reported. §2 bug found, reproduced live, fixed, redeployed (119.2 kB). **Fix is uncommitted at time of writing.** |

---

## A. Independent review findings (2026-09-05)

**Status: no production root cause established for the three-symptom report.
One additional failure mechanism reproduced offline in the actual Swift client.
No candidate exceeds 60% confidence; no application patch is justified yet.**

This review read the entire original document, the referenced `spike/README.md`
§2b–§2e, and the relevant working-tree code. Sections 1–7 above preserve the
investigation history. Where their conclusions conflict with the evidence below,
the qualifications in this section supersede them. References to this document's
lines 1–277 identify that original history; code line numbers describe the local
files at review time, not independently verified deployed code.

### A.1 What the evidence establishes

The reported failure remains: an unidentified subset of Slabs Dev 0.4 (4) cards
shows an em dash, no slab photograph, and missing or incorrect Courtyard
confidence. The trigger is not established. No record connects a failing cert,
its previous state, the refresh method, and a reproduction after the photo fix.
Missing confidence and an incorrect nonzero confidence meter must also be
distinguished.

This differs from a simple failure of one upstream request:

- **There are two upstream endpoints.** The original claim that the three fields
  come from "one upstream call" (lines 24–26) conflicts with the separate
  `card-grader-image` lookup described at lines 49–54. Price and confidence are
  also deliberately coupled by the parser, so their simultaneous absence is not
  two independent observations.
- **The referenced history already contains price discrepancies.**
  `spike/README.md:672–678` records cert `129123650` displaying $36.90 and
  `110578584` displaying $172.30 in Courtyard's app while the anonymous endpoint
  returned 404. These are historical observations, not newly repeated probes,
  and neither cert is established as a current three-symptom case. They refute
  universal equivalence between this endpoint's negative response and the app
  having no price.
- **The Swift client can discard all usable fields because one identity field
  has the wrong JSON type.** `CourtyardScannerClient.swift:81–112` decodes the
  entire reply before switching on `status`; its catch returns `.unavailable`.
  `courtyard-scanner.ts:160–189` accepts `raw: any` and forwards `gd.cardNumber`
  without validating that it is a string. Swift's `Identity.cardNumber` is
  `String?`, which permits absence/null but does not accept a present number.
- **An offline reproduction exercised that actual client.** A temporary harness
  compiled the unmodified `CourtyardScannerClient.swift` with a stubbed transport
  that JSON-decodes a supplied response. Both responses contained a positive
  price, confidence, and an image URL; only the type of `identity.cardNumber`
  changed:

  ```text
  identity.cardNumber = "190" -> ok
  identity.cardNumber = 190   -> unavailable
  DecodingError.typeMismatch(String)
  codingPath: identity.cardNumber
  Expected to decode String but found number instead.
  ```

  This proves the failure mechanism, not its occurrence in production. The
  numeric `cardNumber` was synthetic; no affected production payload has been
  captured. The harness invoked `lookup`, not the UI; the downstream consequence
  follows from the `.unavailable` branch in `PriceService.swift:72–75`, which
  applies no new price or photograph. Review-time artifacts were
  `/private/tmp/courtyard-decode-probe.swift` and
  `/private/tmp/courtyard-decode-probe`; temporary files are not durable evidence.
- **Image fetching remains on the price response's critical path.**
  `courtyard-price/index.ts:246–252` awaits the photograph lookup before returning
  the completed price. Catching image errors does not impose a deadline or make
  delivery independent of a stalled request.
- **Unavailable and not-listed do not have identical effects.**
  `PriceWriteback.swift:34–41` clears price for `.notListed` but preserves it for
  `.unreachable`. `CardDetailScreen.swift:229–241` displays different status
  messages. An unavailable response alone does not erase an existing price or
  photograph.

### A.2 Assumptions that remain unverified or are contradicted

| Earlier assumption | What is untested or contradictory, and its consequence |
|---|---|
| The same cards exhibit all three symptoms after the fix (lines 14–27, 277). | No per-card before/after record exists. The report could combine a pricing gap with an earlier image defect. |
| Missing and wrong confidence are one failure (line 19). | The expected bucket, actual lit segments, and raw confidence are absent. A wrong nonzero value may have a separate cause. |
| All three fields share one upstream failure boundary (lines 24–26). | Images use a separate endpoint. Correlated absence does not prove one upstream failure. |
| The requested cert is the cert printed on the slab (lines 38–43). | No affected `CertScan.raw`, parsed cert, stored grader, or outgoing body was recorded. A bad extraction can make every lookup consistently query the wrong input. |
| Every grader inference comes from digit count (lines 38–40, 216–221). | `CertParser.swift:25–29` also recognizes grader-specific URL hosts. The demonstrated CGC cert is ten digits, so the ordinary heuristic already guesses CGC; manually requesting PSA proves susceptibility, not occurrence in the reported scan. |
| A wrong grader always recovers a correct price (lines 45, 96–98). | Recovery stops on 404, 403, 5xx, and network failure; even a successful response can contain no model price. Sample successes do not establish universal recovery. |
| `unresolvable` means all requests returned 400 (lines 78–79, 106). | `courtyard-scanner.ts:337–343` also throws that kind for contradictory identity echoes in HTTP 200 responses. The error kind does not establish an all-400 history. |
| All-400 proves the card is unknown and the behavior is correct (lines 123–124). | `attempt()` classifies by status without examining error bodies. Request rejection or changed upstream validation can be cached as absence. |
| A 404 means Courtyard cannot price the card (the authoritative-absence equivalence in lines 106–109). | The app-price/endpoint-404 observations in `spike/README.md:672–678` contradict universal equivalence. Their underlying cause is still unknown. |
| Any 200 means our path should produce a price (lines 123–124). | `courtyard-scanner.ts:164–169` requires valid confidence and a positive numeric price. A numeric string, missing confidence, or legitimate `0/0` can yield no price despite HTTP 200. |
| The corrected image request necessarily uses the successful pairing (lines 72–75). | `index.ts:228–231` uses optional response echoes, falling back to the original request if absent. It does not derive the pairing from the successful attempt's `sourceKey`; non-string echoes are not consistently normalized. |
| A helper that never throws cannot prevent price delivery (lines 55–56, 197–198). | The handler awaits image fetching before responding. A stall can prevent delivery without throwing inside the helper. |
| Any function-body throw becomes `source_error` (lines 128–132). | The `try` at `index.ts:158` surrounds `fetchCardDetails`; later row construction, grader normalization, and storage are outside it. Cache operations also ignore returned database errors. |
| Reading the Swift no-price branch proves image delivery (lines 249–252). | The branch requires successful whole-reply decoding. `fillCourtyardImage` additionally has an existing-image guard and download early returns (`PriceService.swift:148–164`). |
| `source_error` explains disappearance of an existing price/photo (lines 130–132). | `PriceWriteback.swift:38–41` preserves stored cents, and the unavailable branch does not erase a photograph. This explanation requires previously empty local state or another state-changing event. |
| Absence and failure are indistinguishable throughout the UI (lines 131–132). | The detail screen distinguishes `.notListed` and `.unavailable`. The row's meter also follows the selected price source, which was not recorded. |
| TTL expiry or a refresh proves the repaired path ran (lines 82–90). | Expiry takes effect on a subsequent lookup. Bulk refresh defaults to `force: false`, and a forced request can still serve stale cached success after upstream failure. No post-fix body, cache flag, or timestamp proves the path taken. |
| Guess-keyed caching has caused no visible failure (lines 187–190). | Alternate graders and zero-padding can select different cached outcomes for the intended slab. The assertion that the next request always uses the same representation was not tested. |
| Caching bounds calls to once per cert per day (lines 206–210). | Force bypasses fresh-cache reuse and concurrent misses are not coalesced. The success path does not reuse `cached.image_url` before fetching a new image. |
| Local curls establish deployed access (lines 236–245). | They do not establish the Edge Function's actual headers, egress response, project, or source version. A shared upstream failure can appear card-specific if only cache misses reach it. |
| The deployed photo fix is confirmed on this phone's backend (lines 34, 68–82). | Script size and a local patch do not identify the version serving the phone. The document explicitly says end-to-end verification never happened. |
| QA login failure is definitely the account and blocks all progress (lines 166–172, 259–262). | `invalid_credentials` does not distinguish wrong credentials/project from account state. It blocks that login path, not offline reproduction or diagnostics on the already signed-in phone. |
| Grade normalization agrees with upstream grouping in general (lines 225–229). | One Pristine example does not demonstrate equivalence across Pristine/Gem Mint records and comp groups. This could affect grades/comps, though it does not explain all three blanks. |

The referenced history also calls authentication the "only untested variable"
(`spike/README.md:694`) and later retires it "with evidence" (line 768), without
recording a fresh-token comparison between those conclusions. Neither statement
is an established result.

**Do not apply the mitigation proposed at lines 211–212.** Stopping the image walk
at the first 200-with-empty would stop on exactly the wrong-grader response
already demonstrated at lines 52–54, recreating the known failure.

### A.3 Ranked production hypotheses

Percentages estimate the explanation of the reported production failure, not
whether a code mechanism exists. Mixed causes across different cards remain
possible.

1. **Whole-reply Swift decoding rejects usable data — 35%.**
   A forwarded field such as numeric `gd.cardNumber` reaches a Swift `String?`
   property, decoding throws, the catch returns `.unavailable`, and
   `PriceService` skips price and image application. This explains all three
   absent outputs on a previously empty card, successful upstream curls, and
   survival of the grader-image fix. The mechanism is reproduced offline, but
   no affected production payload supports this exact type mismatch. It does
   not erase previously stored values.
2. **A fresh negative cache row prevents the repaired path from running — 25%.**
   A fresh `fetch_status = not_found` row with `image_url = NULL` returns before
   any upstream lookup (`index.ts:142–151`). Swift receives absence, clears price
   and confidence, and has no scanner image; the photograph stays blank if no
   fallback succeeds. This explains post-deployment persistence and differences
   between cards. A positive row with only a null image cannot explain all three
   symptoms. No affected cache row or verified forced request was recorded.
3. **Deployed upstream rejection affects cache misses — 20%.**
   Fresh hits work; misses reach Courtyard from the Edge Function and receive
   403/429/5xx. Without a stored successful fallback, `index.ts:212–217` returns
   `source_error` before fetching images. Previously empty cards stay blank.
   This explains card-specific appearance without card-specific upstream data
   failure. It does not explain a verified `.notListed` response or erasure of
   an existing value. The User-Agent change is already implemented; the missing
   test is the deployed request and egress response, not another header patch.
4. **Image lookup stalls delivery of a completed price — 10%.**
   Details succeed, the image request stalls, and the client or gateway times
   out before `okReply` arrives. The client returns `.unavailable`. The image
   helper has no explicit abort deadline, and the handler awaits it before
   responding. This explains a photo change affecting price delivery and the
   difference between cache hits and misses. A prompt `{}` response does not
   cause this failure, and no timing evidence currently supports it. Supabase
   documents a 150-second gateway request timeout
   ([limits](https://supabase.com/docs/guides/functions/limits)).
5. **Fresh Courtyard authentication changes coverage for certain certs — 10%.**
   Anonymous pricing could return absence where a valid authenticated request
   resolves the card, causing our function to cache no price/confidence. This
   fits the recorded app-price/anonymous-404 discrepancies, but requires an
   additional missing-image state: `spike/README.md:723–725` says images answered
   both known discrepant certs. Reconsidering this attempted hypothesis is
   justified specifically because the prior bearer was probably expired
   (lines 659–661), and earlier anonymous/authenticated equivalence was tested
   only on a successful cert (lines 699–700). No fresh-token result accompanies
   its later retirement. This is not evidence to implement account connection.

### A.4 Discriminating tests, in execution order

These diagnostics are proposed, not deployed. Preserve the affected card's local
state and cache row before forcing a request. Record the same cert/grader and
request timestamps throughout.

**1. Capture the function response and decoding outcome — hypothesis 1.**

For a diagnostic build, replace the invocation inside
`CourtyardScannerClient.lookup` with the SDK's raw-response decoding overload:

```swift
let reply: Reply = try await Backend.client.functions.invoke(
    "courtyard-price",
    options: .init(body: Body(
        cert: cert, grader: grader.rawValue, force: force
    )),
    decode: { data, response in
        print("CY_WIRE cert=\(cert) grader=\(grader.rawValue) force=\(force) http=\(response.statusCode) body=\(String(decoding: data, as: UTF8.self))")
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            print("CY_DECODE \(String(reflecting: error))")
            throw error
        }
    }
)
```

Also add this line in the existing outer catch, since non-2xx invocation errors
can occur before the decoding closure runs:

```swift
print("CY_FAILURE cert=\(cert) grader=\(grader.rawValue) force=\(force) error=\(String(reflecting: error))")
```

The overload and decoding-error propagation were checked in the local Supabase
Swift SDK (`FunctionsClient.swift:199–225`), and are visible in the
[upstream SDK source](https://github.com/supabase/supabase-swift/blob/main/Sources/Functions/FunctionsClient.swift).

- **Confirms:** the response contains usable price/image data but produces
  `CY_DECODE`, with the exact coding path identifying the rejection.
- **Rules out for this reproduction:** decoding succeeds. A decoded `not_found`
  directs investigation to cache/upstream classification; `source_error` directs
  it to the function's fetch path.
- The offline type-mismatch reproduction proves susceptibility only; capturing
  an affected production reply is what connects it to this defect.

**2. Compare cached and forced lookups in the same phone session — hypothesis 2.**

With the preceding instrumentation, run these lookups in a diagnostic context
that has the affected `card`:

```swift
_ = await CourtyardScannerClient().lookup(
    cert: card.certNumber, grader: card.grader, force: false
)
_ = await CourtyardScannerClient().lookup(
    cert: card.certNumber, grader: card.grader, force: true
)
```

- **Confirms:** the first response is cached absence with no image; the second
  returns the missing data from a fresh lookup.
- **Rules out cache reuse as the continuing cause:** the forced request reaches
  upstream and still fails.
- This revisits the earlier refresh discussion because no recorded post-fix
  request proves `force: true` reached the function. A bulk refresh is not that
  proof. These `lookup` calls inspect responses; they do not apply the returned
  values to the UI, and the forced call can update the server cache.

**3. Record upstream status from the deployed function — hypothesis 3.**

Immediately before status classification in `attempt()`, add:

```ts
console.info("CY_UPSTREAM", JSON.stringify({
  cert,
  grader,
  http: res.status,
  body: res.ok ? undefined : await res.clone().text(),
}));
```

Perform one forced lookup of the affected card and the known-good control
`96679812/psa` through the same function.

- **Confirms:** the affected request receives 403/429/5xx and the function returns
  `source_error` without a successful cached fallback. A similarly rejected
  forced control strengthens an environment-wide explanation.
- **Rules out for this reproduction:** the deployed request obtains a valid
  price response; the loss occurs at a later boundary.

**4. Bracket the awaited image request — hypothesis 4.**

Around the success-path image await, add:

```ts
console.info("CY_IMAGE_BEGIN", {
  cert, grader, t: Date.now(), priceCents: row.price_cents,
});
const imgs = await fetchGraderImages(answeredCert, answeredGrader);
console.info("CY_IMAGE_END", { cert, grader, t: Date.now() });
```

Add `console.info("CY_REPLY", { cert, grader, t: Date.now() })` immediately before
returning the success response.

- **Confirms:** a positive price exists at `CY_IMAGE_BEGIN`, but `CY_IMAGE_END`
  arrives after the client/gateway timeout or never arrives.
- **Rules out:** image lookup and `CY_REPLY` complete before the failed client
  invocation's deadline. A delay after `CY_IMAGE_END` implicates another stage.

**5. Compare anonymous and demonstrably fresh authenticated requests — hypothesis 5.**

Use a token whose authenticated account request has just succeeded. Set
`CY_CERT` and `CY_GRADER` to the reproduced pairing; `129123650/PSA` is the
documented historical comparison. Run the pair close together from one egress:

```sh
curl -sS -w '\nHTTP %{http_code}\n' \
  -H 'User-Agent: Slabs/1.0 (graded-card inventory)' \
  "https://api.courtyard.io/scanner/card-details?cert=$CY_CERT&grader=$CY_GRADER"

curl -sS -w '\nHTTP %{http_code}\n' \
  -H 'User-Agent: Slabs/1.0 (graded-card inventory)' \
  -H "Authorization: Bearer $CY_FRESH_ACCESS_TOKEN" \
  "https://api.courtyard.io/scanner/card-details?cert=$CY_CERT&grader=$CY_GRADER"
```

- **Confirms:** anonymous returns absence while authenticated returns a positive
  price for the same echoed cert/grader.
- **Rules out authentication alone:** both return the same negative result with
  independently verified valid authentication. An expired or rejected token
  leaves the experiment inconclusive.
- This specifically corrects the earlier expired-token/control-selection gap;
  it does not repeat route enumeration, grader variants, or header guessing.

### A.5 Missing evidence required for a production conclusion

- **Affected input:** one printed cert/grader, `CertScan.raw`, stored
  `certNumber`/`grader`, selected UI source, and whether price/photo previously
  existed. Link the report to a first scan, bulk refresh, or detail refresh.
- **Local state before and after:** `courtyardPriceCents`,
  `courtyardConfidence`, `courtyardStatusRaw`, `courtyardAsOf`, `imageUrl`,
  `imageSourceRaw`, `thumbnailData?.count`, and whether those bytes decode as an
  image.
- **One correlated invocation:** outgoing `{cert, grader, force}`, HTTP status,
  complete response JSON, decoding error with `codingPath`, and timestamps.
- **Cache before mutation:** `(grader, cert)`, `source_key`, `fetch_status`,
  `price_cents`, `source_confidence`, `image_url`, and `fetched_at`, including
  alternate-grader and zero-stripped rows for the intended slab.
- **Actual upstream sequence:** each attempted pairing, status, error body,
  identity echo, and duration for both details and photographs.
- **Runtime identity:** installed bundle identifier/build, backend project URL,
  deployed function version/source hash, Edge runtime version, and the Supabase
  Swift revision embedded in that build.
- **App/API discrepancy:** a fresh Courtyard response supporting the displayed
  price, app version, and fresh-token verification, rather than only a previously
  populated screenshot.
- **Wrong confidence:** raw upstream confidence, stored confidence, selected
  source, actual lit segments, and expected segments.

### A.6 Current fix decision

No hypothesis exceeds 60% confidence. The local decoding reproduction establishes
a real failure mechanism, but no production payload connects it to the reported
cards. Capture the affected invocation and state before selecting a patch.

---

## 8. RESOLVED — a missing request header, 2026-09-06

**`/scanner/card-details` needs `cy-supports-acquisition-status: 1`.** Courtyard's
own app sends it on every `/scanner/*` call. We never did. Without it the endpoint
answers `404 {"message":"card details not found"}` for a large class of certs; with
it, the identical request returns a full priced record.

Full evidence, the disassembly that found it, and everything ruled out first is in
`spike/README.md` §2f. This section records only what it means for the six cards.

### 8.1 The six failing certs all price

Live, 2026-09-06, varying only that header. Every value matches what the owner's
screenshot of Courtyard's own app showed:

| cert | without header | with header | app screenshot |
|---|---|---|---|
| 60478273 | 404 | $183.90 conf 5 | Moltres & Zapdos & Articuno GX #44 $183.90 |
| 62320645 | 404 | $16.90 conf 5 | Reshiram #017 $16.90 |
| 60928769 | 404 | $144.40 conf 5 | Mewtwo #3 $144.40 |
| 60928772 | 404 | $180.90 conf 5 | Pikachu #4 $180.90 |
| 60928787 | 404 | $70.50 conf 5 | Electabuzz #2 $70.50 |
| 66581638 | 404 | $155.40 conf 5 | Radiant Charizard #011 $155.40 |

PSA's own cert page independently confirms 60928769 is the 1999 Pokemon Game Movie
#3 Mewtwo, PSA 9 — so the barcode read, the grader guess and the cert were all
correct the whole time. **The em dash was ours.**

### 8.2 What this overturns in this document

- **§3 Hypothesis A is WRONG.** "Those certs are genuinely unknown to GemRate (NOT a
  bug)" — they are known, and it is a bug. The prediction that it "fits the report
  suspiciously well" was correct for the wrong reason.
- **§3 Hypothesis B is CORRECT in outcome but not in mechanism.** Something in our
  request was wrong; it was not a throw in the function body, it was a header the
  function never sent.
- **§5's acceptance-bar table is misleading.** Cert `133653550`, recorded there and
  in `supabase/functions/README.md` as the authoritative-404 case, prices at $125.40
  with the header. **There is currently no verified not_found fixture cert.**
- **Appendix A.3's ranking is settled.** #1 (Swift decode) was killed by real payload
  types; #2, #3 and #4 were killed by the forced refresh in the Step 2 protocol. #5
  (fresh Courtyard authentication) was the closest — it correctly suspected the
  request, but the variable was the header, not the token. A fresh Privy bearer
  returns the identical 404.
- **§2's grader-image fix stays.** It is correct and it addresses a real bug; it
  simply never touched these cards. Zero of the 40 rows in `cy_scan_cache` ever had a
  grader corrected.

### 8.3 The fix, not yet applied

1. **Send the header** in `supabase/functions/_shared/courtyard-scanner.ts`, at BOTH
   call sites (`attempt()` and `fetchGraderImages()`), beside `SCANNER_UA` and with a
   header comment of the same weight — it is load-bearing in exactly the same way.
2. **Assert it in the vitest suite** the way `SCANNER_UA` is asserted, so it cannot be
   dropped silently.
3. **Deploy `courtyard-price`**, then **purge the stale negatives**:
   `delete from cy_scan_cache where fetch_status = 'not_found';` — 15 rows at time of
   writing. Waiting out the 24h TTL means serving a known-wrong em dash all day.
4. **Replace the 404 fixture cert** in `supabase/functions/README.md` and
   `spike/README.md` §2b with one verified to 404 *with* the header.
5. **Re-run the app** against the six certs to confirm the rows fill.

### 8.4 Still open, and unrelated

**The missing slab photographs are a separate, upstream problem.**
`card-grader-image` returns `200 {"primaryImages": null, "status": "NO_IMAGE"}` for
certs that price perfectly (47849607, 61113679, 60928769, 66581638), with or without
the header. §2e's "9 of 9 coverage" does not generalise — it was a biased sample of
certs already in Courtyard's store. Also note the real empty shape is `null` plus
`status: "NO_IMAGE"`, not "200 with an EMPTY array" as §2 and the adapter comment say.

Two smaller items survive: `index.ts` still fetches an image only on a network miss,
so an `ok` row with a null `image_url` never backfills within its TTL (§4.5-adjacent);
and §4.2's QA account returns `invalid_credentials`, which is a wrong email/password,
**not** an unconfirmed account — that would be `email_not_confirmed`.
