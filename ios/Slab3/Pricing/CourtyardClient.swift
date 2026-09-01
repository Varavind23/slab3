import Foundation

/// Queries Courtyard's Algolia search directly (public search key, no server,
/// no Cloudflare — see spike/README.md §2 and worker/src/sources/courtyard-algolia).
/// Mirrors the worker adapter so client and server agree.
///
/// Records carry both a price (estimatedValueUsd) and card metadata, so a match
/// yields the Courtyard price AND enough to auto-fill name/set/grade/year.
struct CourtyardClient {
    private static let app = "Y8TL3M06QA"
    private static let key = "3b3ed18284ca0baee9a496aea5f093d6" // public search-only
    private static let index = "marketplace_prod_recently_listed"
    /// Sibling index found 2026-08-29 — the comps feed behind `recentSales`.
    private static let soldIndex = "marketplace_prod_recently_sold"

    struct Match {
        let priceCents: Int
        let objectID: String
        let confidence: Confidence
        /// Courtyard's OWN 1-5 confidence in its value estimate — the figure its
        /// app shows beside the price. Distinct from `confidence` above, which is
        /// how sure WE are that this is the right card.
        let sourceConfidence: Int?
        // Metadata for auto-fill (present when Courtyard has the card).
        let name: String?
        /// Courtyard's listing headline, e.g. "2021 Celebrations - Classic
        /// Collection #4 Charizard - Base Set Holo (PSA 10 GEM MINT)". Display
        /// only — `name` is the short one that feeds card_key.
        let title: String?
        let set: String?
        let year: Int?
        let grade: String?
        let cardNumber: String?
        /// Courtyard's own render of the graded card, keyed by cert
        /// (.../graded-cards-renders/PSA%2098881872/nft_image.jpg), plus a
        /// ~90-byte inline preview that can be shown before the fetch lands.
        let imageUrl: URL?
        let lqipBase64: String?
    }
    enum Confidence { case exact, probable, fuzzy }

    /// Why a lookup produced no price. `notListed` (the search worked, Courtyard
    /// has nothing for this card) and `failed` (offline, Algolia error, bad
    /// response) used to both come back as `nil`, so the caller cleared a good
    /// price whenever the network hiccuped. They are separate answers now.
    enum Outcome {
        case match(Match)
        case notListed
        case failed
    }

    /// Look up a card's Courtyard price. Tries the strongest query we have
    /// (name + set) and falls back to the cert number, because the index is
    /// `recently_listed`: a card that matched by name last week can drop out of
    /// it, while the exact vaulted slab still resolves by cert.
    func lookup(grader: Grader, certNumber: String, name: String?, set: String?, grade: String?,
                year: Int? = nil, cardNumber: String? = nil) async -> Outcome {
        let named = [name, set].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // Deduped, in priority order: identity first, cert as the fallback.
        let queries = named.isEmpty ? [certNumber] : [named, certNumber]

        var sawFailure = false
        for query in queries {
            do {
                let result = try await search(query: query, grader: grader)
                if let match = bestMatch(in: result.hits, certNumber: certNumber, grade: grade,
                                         year: year, cardNumber: cardNumber) {
                    return .match(match)
                }
            } catch {
                sawFailure = true
            }
        }
        // Every query that ran came back empty → Courtyard genuinely has nothing.
        // If any of them errored, we don't actually know that.
        return sawFailure ? .failed : .notListed
    }

    /// Pick the best hit that actually carries a price. Ranking a priceless hit
    /// first used to sink the whole lookup even when a good hit sat behind it.
    ///
    /// Two tiers ONLY, both of which must identify the same card:
    ///   • `.exact`    — the cert matches, so it is literally this slab.
    ///   • `.probable` — a different slab of the SAME card: year, card number and
    ///     grade all agree.
    /// Anything looser returns nil, and the caller reports `notListed`.
    ///
    /// There used to be a third tier that took the top priced hit when nothing
    /// agreed. On a query like "Stephen Curry Splash" that is a lottery across
    /// every Splash card Courtyard has ever vaulted: cert 96679812 (2022 Optic
    /// Splash! #10 Holo, PSA 10) is not in the index at all, and we showed the
    /// $18 price of an unrelated Curry against it while Courtyard's own app said
    /// $50.80. Grade alone was no better — it matched a 2024 #2 Purple. A price
    /// belonging to another card is a fabricated price for this one, and the em
    /// dash is what we owe the user instead.
    private func bestMatch(in hits: [Hit], certNumber: String, grade: String?,
                           year: Int?, cardNumber: String?) -> Match? {
        let priced = hits.filter { Self.usd($0) != nil }
        guard !priced.isEmpty else { return nil }

        guard let (hit, confidence) = Self.identify(in: priced, certNumber: certNumber, grade: grade,
                                                    year: year, cardNumber: cardNumber),
              let usd = Self.usd(hit) else { return nil }

        let meta = hit.metadata?.values ?? [:]
        return Match(
            priceCents: Int((usd * 100).rounded()),
            objectID: hit.objectID,
            confidence: confidence,
            // Courtyard's own confidence is quoted ONLY on an exact cert match.
            // On any looser hit the value belongs to a different slab, so passing
            // Courtyard's confidence in it along would overstate what we know —
            // the same rule that keeps a non-exact hit's image off the row.
            sourceConfidence: confidence == .exact ? hit.estimatedValueConfidence?.value : nil,
            name: Self.shortName(in: meta),
            title: hit.title,
            set: meta["Set"],
            year: meta["Year"].flatMap { Int($0) },
            grade: hit.certification?.grade ?? meta["Grade"],
            cardNumber: meta["Card Number"],
            imageUrl: hit.imageUrl.flatMap(URL.init(string:)),
            lqipBase64: hit.lqipBase64
        )
    }

    /// Which hit, if any, is THIS card — and how sure we are. The one place the
    /// identification bar is defined, so price and comps cannot drift apart.
    private static func identify(in hits: [Hit], certNumber: String, grade: String?,
                                 year: Int?, cardNumber: String?) -> (Hit, Confidence)? {
        if let byCert = hits.first(where: { $0.certification?.number == certNumber }) {
            return (byCert, .exact)
        }
        let gnum = gradeNumber(grade)
        let sameCard = hits.first { hit in
            guard let gnum,
                  gradeNumber(hit.certification?.grade ?? hit.metadata?.values["Grade"]) == gnum
            else { return false }
            let meta = hit.metadata?.values ?? [:]
            // Year AND card number must both be known and both agree — either one
            // alone still spans different cards in the same set.
            guard let year, let yr = meta["Year"].flatMap({ Int($0) }), yr == year,
                  let cardNumber, !cardNumber.isEmpty,
                  let num = meta["Card Number"], num.caseInsensitiveCompare(cardNumber) == .orderedSame
            else { return false }
            return true
        }
        return sameCard.map { ($0, .probable) }
    }

    /// The card's short name out of Courtyard's metadata.
    ///
    /// The key is CATEGORY-dependent: Pokémon records use `Title/PKMN`, others
    /// `Title/Subject`. This used to read only `"Title/Subject"` and fall back to
    /// the listing headline, so for Pokémon — the app's main category — it always
    /// took the long headline instead, which then fed `card_key` through `name`.
    /// Matching the prefix is what actually finds it. Sorted for determinism;
    /// real records carry exactly one `Title/` key.
    static func shortName(in meta: [String: String]) -> String? {
        meta.keys.sorted().first { $0.hasPrefix("Title/") }.flatMap { meta[$0] }
    }

    private static func usd(_ hit: Hit) -> Double? {
        hit.estimatedValueUsd ?? hit.latestListing?.price?.amount?.usd
    }

    // MARK: Algolia request

    private func search(query: String, grader: Grader, index: String = CourtyardClient.index) async throws -> AlgoliaResult {
        var req = URLRequest(url: URL(string: "https://\(Self.app.lowercased())-dsn.algolia.net/1/indexes/\(index)/query")!)
        req.httpMethod = "POST"
        req.setValue(Self.app, forHTTPHeaderField: "X-Algolia-Application-Id")
        req.setValue(Self.key, forHTTPHeaderField: "X-Algolia-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "hitsPerPage": 10,
            "facetFilters": [["metadata.Grader:\(grader.rawValue.uppercased())"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: req)
        // A 4xx/5xx from Algolia is a failure, not "no results" — decoding it
        // would otherwise throw and read the same as an empty index.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AlgoliaResult.self, from: data)
    }

    /// "10 GEM MINT" / "PSA 9" / "9.5" → "10" / "9" / "9.5". Leading number only.
    /// Lives in GradeText now — every source normalizes through the same rule, so
    /// one card cannot occupy two card_keys depending on who answered first.
    static func gradeNumber(_ grade: String?) -> String? { GradeText.normalized(grade) }
    // MARK: Sales (comps)

    /// Real recent sales of this card at this grade, newest first.
    ///
    /// Two hops, both unauthenticated: the `recently_sold` Algolia index gives
    /// candidate slabs, and each slab's own ledger
    /// (api.courtyard.io/index/asset/{id}/transactions) carries the actual sale
    /// amount in USDC 6-decimals. `proofOfIntegrity` on a hit IS the assetID.
    ///
    /// COVERAGE IS THIN BY NATURE: only about one vaulted slab in five has ever
    /// sold on Courtyard — the rest were minted and held. An empty list is the
    /// common, honest answer; we never pad it with estimates.
    /// Mirrors worker/src/sources/courtyard-sales.ts.
    func recentSales(name: String?, set: String?, grader: Grader, grade: String?,
                     certNumber: String = "", year: Int? = nil, cardNumber: String? = nil) async -> [RecentSale] {
        let query = [name, set].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // Same identification bar as the price: this slab, or a different slab of
        // the SAME card. Comps for a card that merely shares a player name are
        // not comps. Note this deliberately does NOT require the hit to be priced
        // — we only need it to name an asset whose history we can read.
        guard let result = try? await search(query: query, grader: grader, index: Self.soldIndex),
              let (hit, _) = Self.identify(in: result.hits, certNumber: certNumber, grade: grade,
                                           year: year, cardNumber: cardNumber)
        else { return [] }

        let assetId = hit.proofOfIntegrity ?? hit.objectID
        return await Self.priceHistory(assetId: assetId, grader: grader, grade: grade)
    }

    /// Courtyard's own sale history for the CARD, from
    /// /index/asset/{id}/price-history — unauthenticated, and far richer than the
    /// on-chain ledger it replaced (2026-08-29).
    ///
    /// The ledger only knew about slabs that had traded ON Courtyard — about one
    /// in five — so most cards showed nothing. This endpoint returns Courtyard's
    /// full sale record for the card, split BY GRADE with population, so we can
    /// take exactly our grade's sales. It is keyed to an asset but describes the
    /// card, so any vaulted slab of the same card answers for all of them.
    private static func priceHistory(assetId: String, grader: Grader, grade: String?) async -> [RecentSale] {
        guard let url = URL(string: "https://api.courtyard.io/index/asset/\(assetId)/price-history") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let history = try? JSONDecoder().decode(PriceHistory.self, from: data)
        else { return [] }

        let gnum = Self.gradeNumber(grade)
        // Our grade only. A PSA 10 sale is not a comp for a PSA 9.
        guard let bucket = history.priceHistory.first(where: {
            $0.grader.caseInsensitiveCompare(grader.rawValue) == .orderedSame
                && Self.gradeNumber($0.grade) == gnum
        }) else { return [] }

        return bucket.sales.compactMap { sale -> RecentSale? in
            guard let soldAt = ISO8601.date(sale.date),
                  let dollars = Double(sale.price), dollars > 0 else { return nil }
            return RecentSale(priceCents: Int((dollars * 100).rounded()), soldAt: soldAt,
                              platform: "Courtyard", listingType: nil, title: bucket.title, url: nil)
        }
        .sorted { $0.soldAt > $1.soldAt }
        .prefix(5).map { $0 }
    }

}

// MARK: - Algolia response models

private struct AlgoliaResult: Decodable {
    let hits: [Hit]
}
private struct Hit: Decodable {
    let objectID: String
    let title: String?
    let imageUrl: String?
    let lqipBase64: String?
    let estimatedValueUsd: Double?
    /// Sent as a STRING ("4") on live records — decoded leniently below.
    let estimatedValueConfidence: LenientInt?
    let proofOfIntegrity: String?
    let certification: Cert?
    let metadata: LenientStringDict?
    let latestListing: Listing?
}

/// Decodes an object keeping only its string-valued entries (Algolia metadata is
/// string-valued in practice, but this never throws on an unexpected type).
private struct LenientStringDict: Decodable {
    let values: [String: String]
    private struct Key: CodingKey {
        var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }; init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        var out: [String: String] = [:]
        for k in c.allKeys { if let s = try? c.decode(String.self, forKey: k) { out[k.stringValue] = s } }
        values = out
    }
}
/// Courtyard sends confidence as a string on some records and a number on others.
private struct LenientInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = Int(d.rounded()) }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else { value = nil }
    }
}

/// api.courtyard.io/index/asset/{id}/price-history — the card's sale record,
/// split by grade. `price` is a decimal STRING ("119.95").
private struct PriceHistory: Decodable {
    let priceHistory: [Bucket]
}
private struct Bucket: Decodable {
    let title: String
    let grader: String
    let grade: String
    let population: Int?
    let sales: [HistorySale]
}
private struct HistorySale: Decodable {
    let date: String
    let price: String
}

private struct Cert: Decodable {
    let number: String?
    let grade: String?
}
private struct Listing: Decodable {
    let price: PriceBox?
}
private struct PriceBox: Decodable {
    let amount: AmountBox?
}
private struct AmountBox: Decodable {
    let usd: Double?
}
